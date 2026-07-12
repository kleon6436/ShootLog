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
    var isInspectorVisible: Bool = true
    var sidebarToggleRequestID = UUID()
    var inspectorToggleRequestID = UUID()

    // 編集
    var currentEditInfo: EditInfo?
    var isCropMode: Bool = false

    // 選択中写真のインデックス
    var selectedIndex: Int {
        photos.firstIndex(where: { $0.id == selectedPhoto?.id }) ?? 0
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

    func selectNext() {
        guard !photos.isEmpty else { return }
        selectPhoto(photos[min(selectedIndex + 1, photos.count - 1)])
    }

    func selectPrevious() {
        guard !photos.isEmpty else { return }
        selectPhoto(photos[max(selectedIndex - 1, 0)])
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
        guard photo.cameraModel == nil else { return }
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
            for photo in photos where photo.cameraModel == nil {
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

    func setInspectorVisible(_ isVisible: Bool) {
        isInspectorVisible = isVisible
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
