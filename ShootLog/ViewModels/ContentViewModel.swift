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

    // MARK: - Setup

    // ContentView.onAppear で呼ぶ。以降のすべての操作で内部的に使う
    func configure(context: ModelContext) {
        modelContext = context
        loadHistories()
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
            try? modelContext?.save()
        } catch {
            // EXIF 読み取り失敗は非致命的。無視する
        }
    }

    // MARK: - External App

    // 選択中写真を指定の外部アプリで開く
    func openInExternalApp(_ adapter: any ExternalAppProtocol) {
        guard let url = selectedPhoto?.fileURL else { return }
        adapter.open(url: url)
    }

    // MARK: - Analysis

    var showAnalysis = false

    // 分析シートを開き、未取得EXIFをバックグラウンドで一括ロードする
    // @Model は Sendable でないためシーケンシャルに処理する。EXIFService actor 内で I/O は並列化される
    func openAnalysis() {
        guard !photos.isEmpty else { return }
        showAnalysis = true
        Task {
            for photo in photos where photo.exifFetchedAt == nil {
                await loadEXIFIfNeeded(for: photo)
            }
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

    private func syncPhotos(urls: [URL], context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Photo>())) ?? []
        let byURL = Dictionary(all.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [Photo] = []
        for url in urls {
            if let existing = byURL[url] {
                result.append(existing)
            } else {
                let photo = Photo(id: UUID(), fileURL: url)
                context.insert(photo)
                result.append(photo)
            }
        }
        photos = result
        try? context.save()
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

        if all.count >= 10 { all[9...].forEach { context.delete($0) } }
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
