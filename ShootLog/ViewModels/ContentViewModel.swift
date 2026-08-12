import SwiftData
import Foundation

// アプリ全体の単一真実源。フォルダ管理・写真データ・表示モードをすべて管理する
@Observable
@MainActor
final class ContentViewModel {
    // フォルダ
    var currentFolderURL: URL?
    var folderHistories: [FolderHistory] = []

    // 実体が存在しないと判定されたフォルダ履歴。レコード自体は削除せず表示からのみ除外する
    // （外付けドライブやNASを再接続したときに自動で一覧へ復帰させるため）
    var unavailableHistoryIDs: Set<PersistentIdentifier> = []

    // 実体が存在するフォルダ履歴のみ。EmptyStateViewへ渡す表示用の一覧
    var availableFolderHistories: [FolderHistory] {
        folderHistories.filter { !unavailableHistoryIDs.contains($0.persistentModelID) }
    }

    // 写真
    var photos: [Photo] = []
    var selectedPhoto: Photo?
    var isLoading = false
    var error: (any Error)?
    var toastMessage: String?

    // お気に入りのみ表示フラグ。ツールバー（ContentView）とSidebarViewModelの絞り込み双方から参照される共有状態
    var showFavoritesOnly: Bool = false

    // 表示モード
    var currentModeID: String = "sidebar"
    var isSidebarVisible: Bool = true
    var isInspectorVisible: Bool = false
    var sidebarToggleRequestID = UUID()
    var inspectorToggleRequestID = UUID()

    // ウィンドウツールバーの可視性。ContentViewが WindowChromeConfigurator へ渡す単一の真実源で、
    // フルスクリーンのHUD自動隠れ（FullscreenViewModel）から更新される。
    // フルスクリーン以外のモードでは常に true（FullscreenViewModel.endHUDSession が復帰させる）
    var isToolbarVisible: Bool = true

    // 編集
    var currentEditInfo: EditInfo?
    var isCropMode: Bool = false

    // 選択中写真のインデックス（未フィルタの photos 基準）
    var selectedIndex: Int {
        photos.firstIndex(where: { $0.id == selectedPhoto?.id }) ?? 0
    }

    // 連携アプリ設定。ContentViewの@Queryから渡される（SwiftDataの変更をObservationで
    // 検知しツールバーの外部アプリメニューへ反映するため、ここでの直接fetchは行わない）
    private var integrationSettings: [IntegrationAppSetting] = []

    // showFavoritesOnly を適用した写真配列。フルスクリーン/スライドショーの写真切替・
    // カウンタ表示、selectNext()/selectPrevious() の絞り込み基準として使う単一の真実源
    // （searchText の絞り込みは SidebarViewModel.displayedPhotos 側の責務のためここには含めない）
    var visiblePhotos: [Photo] {
        guard showFavoritesOnly else { return photos }
        return photos.filter { $0.isFavorite }
    }

    // visiblePhotos 内での選択中写真の位置。絞り込みによって選択中写真が一覧から
    // 外れている場合（お気に入りのみ表示をONにした直後、表示中写真のお気に入りを
    // 解除した直後）は nil を返す。0 へフォールバックするとカウンタ・ページドットが
    // 実際の表示写真と異なる位置を指してしまうため
    var visibleIndex: Int? {
        guard let selectedPhoto else { return nil }
        return visiblePhotos.firstIndex(where: { $0.id == selectedPhoto.id })
    }

    // Folder/Edit/PhotoActions extension から参照するため internal（既定アクセス）とする
    var modelContext: ModelContext?
    var bookmarkScopedURL: URL?
    private var toastTask: Task<Void, Never>?

    // 段階挿入（先頭N件を即時表示し、残りを逐次insert）の残り分を処理するTask。
    // フォルダ切替時にキャンセルする。Folder/PhotoActions extension双方から参照する
    var photoStagingTask: Task<Void, Never>?

    // 段階挿入の世代番号。キャンセル直後に古いTaskが photos を更新してしまうのを防ぐ
    var photoStagingGeneration = 0

    // 段階挿入中に一覧末尾で「次へ」が押された際の待機Task。
    // 連打で複数溜まらないよう常に1本だけ保持し、フォルダ切替時にキャンセルする
    var pendingSelectNextTask: Task<Void, Never>?

    // 分析シートのEXIF一括取得Task。シートを開き直した際に前回分をキャンセルする
    var analysisTask: Task<Void, Never>?

    // フォルダ履歴の存在確認Task。loadHistories() の再実行時に前回分をキャンセルする
    var historyAvailabilityTask: Task<Void, Never>?

    // グリッドの初期表示に必要な可視セル数の目安。この件数までは即時にinsert/saveする
    static let initialPhotoBatchSize = 50

    // 段階挿入の2回目以降で1度に処理する件数
    static let photoStagingChunkSize = 100

    // MARK: - Setup

    // ContentView.onAppear で呼ぶ。以降のすべての操作で内部的に使う
    func configure(context: ModelContext) {
        modelContext = context
        applyGeneralSettingsDefaults()
        loadHistories()
    }

    // 「一般」設定タブで指定された起動時の既定値を反映する
    private func applyGeneralSettingsDefaults() {
        let defaults = UserDefaults.standard
        currentModeID = defaults.string(forKey: AppSettingsKeys.defaultViewModeID)
            ?? AppSettingsKeys.defaultViewModeIDDefault
        showFavoritesOnly = defaults.bool(forKey: AppSettingsKeys.defaultFavoritesOnly)
        isInspectorVisible = defaults.bool(forKey: AppSettingsKeys.defaultInspectorVisible)
    }

    // ContentViewの@Queryが検知したIntegrationAppSettingの変更を反映する
    func updateIntegrationSettings(_ settings: [IntegrationAppSetting]) {
        integrationSettings = settings
    }

    // MARK: - Analysis

    var showAnalysis = false

    // MARK: - Mode

    func switchToSidebar() { currentModeID = "sidebar" }

    func requestSidebarToggle() {
        sidebarToggleRequestID = UUID()
    }

    func requestInspectorToggle() {
        inspectorToggleRequestID = UUID()
    }

    func setSidebarVisible(_ isVisible: Bool) {
        isSidebarVisible = isVisible
    }

    // サイドバー/インスペクタの表示切替・可視性表示が有効な条件（sidebarモード表示中かつフォルダ選択済み）
    // ContentView の FocusedValues 判定で共通利用する
    var isSidebarModeActive: Bool {
        currentModeID == "sidebar" && currentFolderURL != nil
    }

    // MARK: - Toolbar (ModeToolbarComponents向け)

    // ツールバーのモード切替セグメントに表示する、有効化済み表示モード一覧
    var availableModes: [any ViewModeProtocol] {
        ViewModeRegistry.shared.enabledModes
    }

    // ツールバーの外部アプリメニューに表示する、利用可能な外部アプリ一覧。
    // IntegrationAppSetting（有効/無効・表示順序・カスタムアプリ）とアダプター実装を突き合わせて組み立てる。
    // settingsはContentViewの@Query経由でupdateIntegrationSettings(_:)により渡される
    // （ここでmodelContext.fetchを直接呼ぶとObservationが変更を追跡できずツールバーに反映されない）
    var externalApps: [any ExternalAppProtocol] {
        let builtInAdapters = ExternalAppRegistry.shared.builtInAdapters
        let settings = integrationSettings

        // 設定が未作成の場合はビルトイン全てを有効とみなす（既存動作との後方互換）
        guard !settings.isEmpty else {
            return builtInAdapters.filter { $0.isAvailable }
        }

        var resolved: [any ExternalAppProtocol] = []
        var configuredBuiltInIDs: Set<String> = []
        for setting in settings {
            if setting.isCustom {
                guard setting.isEnabled else { continue }
                resolved.append(
                    CustomAppAdapter(
                        id: setting.identifier,
                        displayName: setting.customDisplayName ?? setting.identifier
                    )
                )
            } else {
                configuredBuiltInIDs.insert(setting.identifier)
                guard setting.isEnabled,
                      let adapter = builtInAdapters.first(where: { $0.id == setting.identifier })
                else { continue }
                resolved.append(adapter)
            }
        }

        // 設定に存在しないビルトイン（アダプター追加直後など）は機能が消えたように見えないよう暗黙的に有効として末尾へ追加する
        resolved.append(contentsOf: builtInAdapters.filter { !configuredBuiltInIDs.contains($0.id) })

        // 最終的にインストール済みのアプリのみへ絞り込む（配列は sortOrder 昇順のまま）
        return resolved.filter { $0.isAvailable }
    }

    // MARK: - Shared Helpers

    // トースト通知を表示する。PhotoActions extension（toggleFavorite）からも呼ばれるため internal
    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toastMessage = nil }
        }
    }

    // ユーザー操作直結の保存処理をまとめる。失敗時は握り潰さず error へセットしてAlert通知し、falseを返す。
    // 呼び出し側は戻り値で保存成否を判定できる（例: 保存失敗時に成功トーストを出さないため）。
    // Folder/Edit/PhotoActions extensionから呼ばれるため internal
    @discardableResult
    func saveOrReportError(_ context: ModelContext) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            self.error = ShootLogError.photoDataSaveFailed
            return false
        }
    }
}
