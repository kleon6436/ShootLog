import AppKit
import SwiftData
import UniformTypeIdentifiers
import Foundation

// アプリ全体の単一真実源。フォルダ管理・写真データ・表示モードをすべて管理する
@Observable
@MainActor
final class ContentViewModel {
    // フォルダ
    var currentFolderURL: URL?
    var folderHistories: [FolderHistory] = []

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

    private var modelContext: ModelContext?
    private var bookmarkScopedURL: URL?
    private var toastTask: Task<Void, Never>?

    // 段階挿入（先頭N件を即時表示し、残りを逐次insert）の残り分を処理するTask。
    // フォルダ切替時にキャンセルする
    private var photoStagingTask: Task<Void, Never>?

    // 段階挿入の世代番号。キャンセル直後に古いTaskが photos を更新してしまうのを防ぐ
    private var photoStagingGeneration = 0

    // 段階挿入中に一覧末尾で「次へ」が押された際の待機Task。
    // 連打で複数溜まらないよう常に1本だけ保持し、フォルダ切替時にキャンセルする
    private var pendingSelectNextTask: Task<Void, Never>?

    // 分析シートのEXIF一括取得Task。シートを開き直した際に前回分をキャンセルする
    private var analysisTask: Task<Void, Never>?

    // グリッドの初期表示に必要な可視セル数の目安。この件数までは即時にinsert/saveする
    private static let initialPhotoBatchSize = 50

    // 段階挿入の2回目以降で1度に処理する件数
    private static let photoStagingChunkSize = 100

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

    // MARK: - Folder

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "写真フォルダを選択してください"
        panel.prompt = "開く"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await selectFolder(url: url) }
    }

    func handleProviderDrop(provider: NSItemProvider) async {
        guard let url = await loadFileURL(from: provider) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        await selectFolder(url: url)
    }

    func restoreFolder(_ history: FolderHistory) async {
        releaseBookmarkAccess()
        guard let context = modelContext else { return }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: history.securityBookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                error = ShootLogError.folderAccessDenied
                return
            }
            bookmarkScopedURL = url

            if stale, let newBookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                history.securityBookmark = newBookmark
            }
            history.lastAccessedAt = Date()
            try context.save()
            loadHistories()
            currentFolderURL = url
            await loadFolderPhotos(url)
        } catch {
            self.error = ShootLogError.bookmarkRestorationFailed
        }
    }

    func loadHistories() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<FolderHistory>(
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        folderHistories = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Photo Navigation

    // 写真を選択し EditInfo と EXIF を遅延ロードする
    func selectPhoto(_ photo: Photo?) {
        selectedPhoto = photo
        guard let photo else { currentEditInfo = nil; return }
        loadEditInfo(for: photo)
        Task { await loadEXIFIfNeeded(for: photo) }
    }

    // visiblePhotos（showFavoritesOnly適用後）基準で次の写真を選択する。
    // 選択中写真が未選択、または絞り込みで一覧から外れている場合は先頭要素を選ぶ
    // （旧実装は selectedIndex の `?? 0` フォールバックにより未選択時に1枚飛ばすバグがあった）
    func selectNext() {
        let list = visiblePhotos
        guard !list.isEmpty else { return }
        guard let selectedPhoto, let index = list.firstIndex(where: { $0.id == selectedPhoto.id }) else {
            selectPhoto(list.first)
            return
        }
        // 段階挿入中に「まだ挿入されていない次の写真」が存在し得る場合に限り、挿入完了を待って再試行する。
        // 絞り込み末尾が全体の末尾と一致しない場合（お気に入りのみ表示など）は待たずに即クランプする
        if index == list.count - 1,
           let staging = photoStagingTask,
           list.last?.id == photos.last?.id {
            let generation = photoStagingGeneration
            let targetID = selectedPhoto.id
            pendingSelectNextTask?.cancel()
            pendingSelectNextTask = Task { [weak self] in
                await staging.value
                guard let self, !Task.isCancelled,
                      generation == self.photoStagingGeneration,
                      self.selectedPhoto?.id == targetID else { return }
                self.pendingSelectNextTask = nil
                self.selectNext()
            }
            return
        }
        selectPhoto(list[min(index + 1, list.count - 1)])
    }

    func selectPrevious() {
        let list = visiblePhotos
        guard !list.isEmpty else { return }
        guard let selectedPhoto, let index = list.firstIndex(where: { $0.id == selectedPhoto.id }) else {
            selectPhoto(list.first)
            return
        }
        selectPhoto(list[max(index - 1, 0)])
    }

    // MARK: - Edit

    // 選択中写真の EditInfo を SwiftData から取得する（なければ nil）
    func loadEditInfo(for photo: Photo) {
        guard let context = modelContext else { return }
        let all = (try? context.fetch(FetchDescriptor<EditInfo>())) ?? []
        currentEditInfo = all.first(where: { $0.photoID == photo.id })
    }

    // 90° 右回転。EditInfo がなければ新規作成する
    func rotateSelectedPhoto() {
        guard let context = modelContext, let photo = selectedPhoto else { return }
        let info = editInfoOrCreate(for: photo, context: context)
        info.rotation = (info.rotation + 90) % 360
        try? context.save()
    }

    // トリミング矩形を保存して crop モードを終了する
    func setCropRect(_ rect: CGRect?) {
        guard let context = modelContext, let photo = selectedPhoto else { return }
        let info = editInfoOrCreate(for: photo, context: context)
        info.cropRect = rect
        try? context.save()
        isCropMode = false
    }

    func toggleCropMode() {
        guard selectedPhoto != nil else { return }
        isCropMode.toggle()
    }

    // EditInfo を削除して編集を全リセットする
    func resetEdits() {
        guard let context = modelContext, let info = currentEditInfo else { return }
        context.delete(info)
        currentEditInfo = nil
        isCropMode = false
        try? context.save()
    }

    // MARK: - Photo Actions

    // 選択中写真のお気に入りをトグルする（FullscreenMode・SlideshowMode用）
    func toggleFavorite() {
        guard let photo = selectedPhoto else { return }
        toggleFavorite(photo)
    }

    // グリッド・リストからの直接トグル用
    func toggleFavorite(_ photo: Photo) {
        photo.isFavorite.toggle()
        try? modelContext?.save()
        showToast(photo.isFavorite ? "お気に入りに追加しました" : "お気に入りを解除しました")
    }

    func saveNote(_ note: String, for photo: Photo) {
        photo.note = note
        try? modelContext?.save()
    }

    // Step 3: 選択時に EXIF を遅延ロードして Photo に永続化する
    func loadEXIFIfNeeded(for photo: Photo) async {
        guard photo.exifFetchedAt == nil else { return }
        let url = photo.fileURL
        do {
            let exif = try await EXIFService.shared.readEXIF(from: url)
            apply(exif, to: photo)
            try? modelContext?.save()
        } catch {
            // EXIF 読み取り失敗は非致命的。無視する
        }
    }

    // 読み取った EXIF を Photo へ反映する（保存は呼び出し側でまとめて行う）
    private func apply(_ exif: EXIFInfo, to photo: Photo) {
        photo.cameraMake   = exif.cameraMake
        photo.cameraModel  = exif.cameraModel
        photo.lensModel    = exif.lensModel
        photo.aperture     = exif.aperture
        photo.shutterSpeed = exif.shutterSpeed
        photo.iso          = exif.iso
        photo.focalLength  = exif.focalLength
        photo.colorMode    = exif.colorMode
        if let date = exif.shootingDate { photo.shootingDate = date }
        photo.exifFetchedAt = Date()
    }

    // MARK: - External App

    // 選択中写真を指定の外部アプリで開く
    func openInExternalApp(_ adapter: any ExternalAppProtocol) {
        guard let url = selectedPhoto?.fileURL else { return }
        adapter.open(url: url)
    }

    // MARK: - Analysis

    var showAnalysis = false

    // 分析シートを開き、未取得EXIFをバックグラウンドで一括ロードする。
    // AnalysisView は初期化時の写真配列をスナップショットするため、段階挿入中は
    // 全件の挿入完了を待ってからシートを開く（部分集合のまま分析されるのを防ぐ）。
    // @Model は Sendable でないため URL のみを EXIFService へ渡し、読み取りは並列数制限付きで並列化する
    func openAnalysis() {
        guard !photos.isEmpty else { return }
        analysisTask?.cancel()
        analysisTask = Task {
            let generation = photoStagingGeneration
            if let staging = photoStagingTask {
                isLoading = true
                await staging.value
                // フォルダが切り替わった場合は、その分析要求自体を破棄する
                // （isLoading は新しい読み込み側が管理するため触らない）
                guard generation == photoStagingGeneration else { return }
                isLoading = false
            }
            guard !Task.isCancelled, !photos.isEmpty else { return }
            showAnalysis = true

            let targets = photos.filter { $0.exifFetchedAt == nil }
            guard !targets.isEmpty else { return }
            let urls = targets.map(\.fileURL)
            let results = await EXIFService.shared.readEXIFBatch(
                from: urls,
                maxConcurrency: EXIFService.recommendedBatchConcurrency(for: urls.first)
            )
            guard !Task.isCancelled else { return }
            for photo in targets {
                guard let exif = results[photo.fileURL] else { continue }
                apply(exif, to: photo)
            }
            try? modelContext?.save()
        }
    }

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

    // MARK: - Private

    private func selectFolder(url: URL) async {
        guard let context = modelContext else { return }
        releaseBookmarkAccess()
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            addToHistory(url: url, bookmark: bookmark, context: context)
            currentFolderURL = url
            await loadFolderPhotos(url)
        } catch {
            self.error = ShootLogError.folderAccessDenied
        }
    }

    // EditInfo を取得する。なければ新規作成して currentEditInfo にセットする
    private func editInfoOrCreate(for photo: Photo, context: ModelContext) -> EditInfo {
        if let existing = currentEditInfo { return existing }
        let info = EditInfo(photoID: photo.id)
        context.insert(info)
        currentEditInfo = info
        return info
    }

    private func loadFolderPhotos(_ folderURL: URL) async {
        guard let context = modelContext else { return }
        cancelPhotoStaging()
        isLoading = true
        photos = []
        selectedPhoto = nil
        currentEditInfo = nil
        isCropMode = false

        do {
            let urls = try await Task.detached(priority: .utility) {
                try PhotoRepository.scanImageURLs(in: folderURL)
            }.value
            syncPhotos(urls: urls, context: context)
            selectPhoto(photos.first)
        } catch {
            self.error = error
        }
        isLoading = false
    }

    // 先頭 initialPhotoBatchSize 件だけを同期的にinsert/saveしてグリッドを即時表示し、
    // 残りは photoStagingTask で分割して挿入する
    private func syncPhotos(urls: [URL], context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Photo>())) ?? []
        let byURL = Dictionary(all.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })

        let firstBatchCount = min(urls.count, Self.initialPhotoBatchSize)
        photos = urls[..<firstBatchCount].map { resolvePhoto(for: $0, existing: byURL, context: context) }
        try? context.save()

        guard firstBatchCount < urls.count else { return }
        let remaining = Array(urls[firstBatchCount...])
        let generation = photoStagingGeneration
        photoStagingTask = Task {
            await stagePhotos(urls: remaining, existing: byURL, context: context, generation: generation)
        }
    }

    // 残りの写真をチャンク単位でinsertし、グリッドへ逐次追加する。
    // チャンクごとに Task.yield() でメインスレッドを解放し、描画とユーザー操作を挟み込む
    private func stagePhotos(
        urls: [URL],
        existing byURL: [URL: Photo],
        context: ModelContext,
        generation: Int
    ) async {
        var index = 0
        while index < urls.count {
            guard !Task.isCancelled, generation == photoStagingGeneration else { return }
            let end = min(index + Self.photoStagingChunkSize, urls.count)
            let chunk = urls[index..<end].map { resolvePhoto(for: $0, existing: byURL, context: context) }
            photos.append(contentsOf: chunk)
            try? context.save()
            index = end
            await Task.yield()
        }
        if generation == photoStagingGeneration { photoStagingTask = nil }
    }

    // 既存の Photo があれば再利用し、無ければ新規作成してinsertする（重複挿入の防止）
    private func resolvePhoto(for url: URL, existing byURL: [URL: Photo], context: ModelContext) -> Photo {
        if let photo = byURL[url] { return photo }
        let photo = Photo(id: UUID(), fileURL: url)
        context.insert(photo)
        return photo
    }

    // 進行中の段階挿入を打ち切る。フォルダ切替の直前に呼び、古いTaskが photos を汚さないようにする
    private func cancelPhotoStaging() {
        photoStagingTask?.cancel()
        photoStagingTask = nil
        pendingSelectNextTask?.cancel()
        pendingSelectNextTask = nil
        photoStagingGeneration &+= 1
    }

    private func addToHistory(url: URL, bookmark: Data, context: ModelContext) {
        let descriptor = FetchDescriptor<FolderHistory>(
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []

        if let existing = all.first(where: { $0.url == url }) {
            existing.lastAccessedAt = Date()
            existing.securityBookmark = bookmark
            try? context.save()
            loadHistories()
            return
        }

        // 保持件数は「一般」設定タブの値を使う（未設定時は 0 が返るため既定値へフォールバック）
        let storedLimit = UserDefaults.standard.integer(forKey: AppSettingsKeys.folderHistoryLimit)
        let effectiveLimit = storedLimit > 0 ? storedLimit : AppSettingsKeys.folderHistoryLimitDefault
        if all.count >= effectiveLimit { all[(effectiveLimit - 1)...].forEach { context.delete($0) } }
        context.insert(FolderHistory(url: url, bookmark: bookmark))
        try? context.save()
        loadHistories()
    }

    private func releaseBookmarkAccess() {
        bookmarkScopedURL?.stopAccessingSecurityScopedResource()
        bookmarkScopedURL = nil
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toastMessage = nil }
        }
    }
}
