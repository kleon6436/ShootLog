import SwiftUI

// サイドバーモード（SidebarModeView）専用のViewModel。ContentViewModelを保持し、
// サイドバー固有の状態（検索・お気に入りフィルタ・EXIFパネル可視性）はここで管理する
@Observable
@MainActor
final class SidebarViewModel {
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

    // ツールバー（ContentView）のトグルとも同期する必要があるためContentViewModelを単一の真実源とし委譲する
    var showFavoritesOnly: Bool {
        get { content.showFavoritesOnly }
        set { content.showFavoritesOnly = newValue }
    }

    // ツールバーの表示モード切替（Picker）から直接切り替えるためget/set両方必要
    var currentModeID: String {
        get { content.currentModeID }
        set { content.currentModeID = newValue }
    }

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

    var photos: [Photo] { content.photos }

    // PhotoListViewのselectionバインディングに使うため get/set 両方必要。
    // set時はContentViewModel.selectPhoto(_:)相当のロジック（EditInfo/EXIF遅延ロード）を必ず経由させる
    var selectedPhoto: Photo? {
        get { content.selectedPhoto }
        set { content.selectPhoto(newValue) }
    }

    var currentEditInfo: EditInfo? { content.currentEditInfo }

    // onCropCancelから直接falseを代入するためget/set両方必要
    var isCropMode: Bool {
        get { content.isCropMode }
        set { content.isCropMode = newValue }
    }

    var isLoading: Bool { content.isLoading }
    var toastMessage: String? { content.toastMessage }

    func selectNext() { content.selectNext() }
    func selectPrevious() { content.selectPrevious() }
    func loadEditInfo(for photo: Photo) { content.loadEditInfo(for: photo) }
    func loadEXIFIfNeeded(for photo: Photo) async { await content.loadEXIFIfNeeded(for: photo) }
    func setCropRect(_ rect: CGRect?) { content.setCropRect(rect) }
    func rotateSelectedPhoto() { content.rotateSelectedPhoto() }
    func toggleCropMode() { content.toggleCropMode() }
    func resetEdits() { content.resetEdits() }
    func setSidebarVisible(_ isVisible: Bool) { content.setSidebarVisible(isVisible) }
    func openFolder() { content.openFolder() }
    func openAnalysis() { content.openAnalysis() }
    func openInExternalApp(_ adapter: any ExternalAppProtocol) { content.openInExternalApp(adapter) }

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
