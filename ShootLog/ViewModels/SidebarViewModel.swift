import SwiftUI

// サイドバーモード（SidebarModeView）専用のViewModel。ContentViewModelを保持し、
// サイドバー固有の状態（検索・お気に入りフィルタ・EXIFパネル可視性）はここで管理する
@Observable
@MainActor
final class SidebarViewModel: ContentViewModelProxy {
    // サイドバー（左カラム）表示状態の永続化用。
    // 2カラムの NavigationSplitView では「サイドバー+詳細」が .doubleColumn、
    // 「詳細のみ」が .detailOnly（.all は3カラム用のため使わない）
    enum ColumnVisibilityState: String {
        case visible
        case hidden

        init(_ visibility: NavigationSplitViewVisibility) {
            self = visibility == .detailOnly ? .hidden : .visible
        }

        var navigationVisibility: NavigationSplitViewVisibility {
            switch self {
            case .visible:
                .doubleColumn
            case .hidden:
                .detailOnly
            }
        }

        // 旧バージョン（3カラム構成）の保存値との互換変換。
        // 当時は「左+中央+右」= "all"、「中央+右（サイドバー非表示）」= "doubleColumn"、
        // 「右のみ」= "detailOnly" を保存していたため、サイドバー非表示にあたる旧値は
        // 明示的に .hidden へ写像する。それ以外（"all"・"automatic"・未知の値）のみ .visible にフォールバックする
        static func restored(from stored: String) -> ColumnVisibilityState {
            if let state = ColumnVisibilityState(rawValue: stored) {
                return state
            }
            switch stored {
            case "detailOnly", "doubleColumn":
                return .hidden
            default:
                return .visible
            }
        }
    }

    let content: ContentViewModel

    // 検索テキスト
    var searchText: String = ""
    // EXIFパネル可視性フラグ
    var isEXIFPanelVisible: Bool {
        get { content.isInspectorVisible }
        set { content.isInspectorVisible = newValue }
    }

    var isSidebarVisible: Bool { content.isSidebarVisible }
    var sidebarToggleRequestID: UUID { content.sidebarToggleRequestID }
    var inspectorToggleRequestID: UUID { content.inspectorToggleRequestID }

    // showFavoritesOnly / currentModeID などの委譲は ContentViewModelProxy のデフォルト実装に任せる

    private var widthSaveTask: Task<Void, Never>?

    init(content: ContentViewModel) {
        self.content = content
    }

    // searchText（ファイル名・カメラ名の部分一致）と showFavoritesOnly の AND 条件で photos を絞り込む
    var displayedPhotos: [Photo] {
        content.photos.filter { photo in
            let matchesSearch = searchText.isEmpty
                || photo.fileURL.lastPathComponent.localizedCaseInsensitiveContains(searchText)
                || (photo.cameraModel?.localizedCaseInsensitiveContains(searchText) ?? false)
            let matchesFavorite = !showFavoritesOnly || photo.isFavorite
            return matchesSearch && matchesFavorite
        }
    }

    // MARK: - ContentViewModel への委譲

    // 単純な委譲は ContentViewModelProxy のデフォルト実装に任せる。
    // 以下はサイドバー固有のセマンティクスを持つため独自に定義する

    // PhotoListViewのselectionバインディングに使うため get/set 両方必要。
    // set時はContentViewModel.selectPhoto(_:)相当のロジック（EditInfo/EXIF遅延ロード）を必ず経由させる
    var selectedPhoto: Photo? {
        get { content.selectedPhoto }
        set { content.selectPhoto(newValue) }
    }

    // onCropCancelから直接falseを代入するためget/set両方必要
    var isCropMode: Bool {
        get { content.isCropMode }
        set { content.isCropMode = newValue }
    }

    var isLoading: Bool { content.isLoading }
    var toastMessage: String? { content.toastMessage }
    var isSelectedPhotoFavorite: Bool { content.selectedPhoto?.isFavorite ?? false }

    func loadEditInfo(for photo: Photo) { content.loadEditInfo(for: photo) }
    func loadEXIFIfNeeded(for photo: Photo) async { await content.loadEXIFIfNeeded(for: photo) }
    func setCropRect(_ rect: CGRect?) { content.setCropRect(rect) }
    func rotateSelectedPhoto() { content.rotateSelectedPhoto() }
    func toggleCropMode() { content.toggleCropMode() }
    func resetEdits() { content.resetEdits() }
    func toggleFavorite() { content.toggleFavorite() }
    func setSidebarVisible(_ isVisible: Bool) { content.setSidebarVisible(isVisible) }

    // MARK: - サイドバー開閉の判定

    // 起動時にAppStorageの保存値からサイドバー可視状態を復元する。
    // NSViewController走査等のAppKit操作自体はView側の責務のため、ここでは
    // 「保存値から表示状態をどう判定するか」という純粋なロジックのみを担う。
    // 戻り値はSwiftUI非依存の ColumnVisibilityState とし、NavigationSplitViewVisibilityへの
    // 変換はView側の責務とする
    func restoreColumnVisibility(from stored: String) -> ColumnVisibilityState {
        let state = ColumnVisibilityState.restored(from: stored)
        setSidebarVisible(state == .visible)
        return state
    }

    // columnVisibilityの変更（トグルボタン・ドラッグ収縮・メニューコマンド起因）を
    // AppStorage保存値とContentViewModelの可視状態フラグへ同期する。
    // NavigationSplitViewVisibility → ColumnVisibilityState の変換はView側で行ってから渡す
    func syncColumnVisibility(_ state: ColumnVisibilityState) -> String {
        setSidebarVisible(state == .visible)
        return state.rawValue
    }

    // サイドバートグル操作（メニューコマンド・ツールバーボタン）でのトグル後の期待表示状態を判定する。
    // AppKit側の実状態（畳まれているか）はView側でNSSplitViewItemから取得済みの値を渡してもらい、
    // ここでは「いつ・どちらの状態にすべきか」の判定のみ行う。実際のAppKit API呼び出し自体はView側で行う
    func resolveSidebarToggleTarget(wasCollapsed: Bool) -> ColumnVisibilityState {
        wasCollapsed ? .visible : .hidden
    }

    // MARK: - サイドバー幅の保存

    // ドラッグ中の高頻度書き込みを避けるため、1pt未満の変化は無視し300msデバウンスしてから保存する
    func scheduleWidthSave(_ newWidth: Double, current sidebarWidth: Binding<Double>) {
        guard abs(newWidth - sidebarWidth.wrappedValue) >= 1 else { return }
        widthSaveTask?.cancel()
        widthSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            sidebarWidth.wrappedValue = newWidth
        }
    }
}
