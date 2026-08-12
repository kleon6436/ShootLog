import AppKit
import SwiftData
import UniformTypeIdentifiers
import Foundation

// フォルダの選択・履歴管理・写真読み込みを担当する
extension ContentViewModel {
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
            saveOrReportError(context)
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
        historyAvailabilityTask?.cancel()
        historyAvailabilityTask = Task { await refreshHistoryAvailability() }
    }

    // ユーザー操作による履歴1件の削除。写真データには影響しない
    func deleteHistory(_ history: FolderHistory) {
        guard let context = modelContext else { return }
        let id = history.persistentModelID
        context.delete(history)
        guard saveOrReportError(context) else { return }
        unavailableHistoryIDs.remove(id)
        loadHistories()
    }

    // 各履歴の実体の有無を並列に確認し、存在しないものを表示対象から外す。
    // フォルダを開いている間は現在のセキュリティスコープと start/stop が競合しうるため実行しない
    func refreshHistoryAvailability() async {
        guard currentFolderURL == nil else { return }
        let targets = folderHistories.map { ($0.persistentModelID, $0.securityBookmark) }
        guard !targets.isEmpty else {
            unavailableHistoryIDs = []
            return
        }

        var unavailable: Set<PersistentIdentifier> = []
        await withTaskGroup(of: (PersistentIdentifier, Bool).self) { group in
            for (id, bookmark) in targets {
                group.addTask {
                    (id, await FolderAvailabilityChecker.isAvailable(bookmark: bookmark))
                }
            }
            for await (id, isAvailable) in group where !isAvailable {
                unavailable.insert(id)
            }
        }

        // 一覧のちらつきを避けるため、判定結果はまとめて一度だけ反映する
        guard !Task.isCancelled else { return }
        unavailableHistoryIDs = unavailable
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
        saveOrReportError(context)

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
            // 段階挿入のバックグラウンド保存。1チャンク失敗しても残りの挿入を止めないためAlert化しない
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
            saveOrReportError(context)
            loadHistories()
            return
        }

        // 保持件数は「一般」設定タブの値を使う（未設定時は 0 が返るため既定値へフォールバック）
        let storedLimit = UserDefaults.standard.integer(forKey: AppSettingsKeys.folderHistoryLimit)
        let effectiveLimit = storedLimit > 0 ? storedLimit : AppSettingsKeys.folderHistoryLimitDefault
        let overflow = all.count - (effectiveLimit - 1)
        if overflow > 0 { evictHistories(from: all, count: overflow, context: context) }
        context.insert(FolderHistory(url: url, bookmark: bookmark))
        saveOrReportError(context)
        loadHistories()
    }

    // 履歴の上限超過分を削除する。実体が存在せず一覧に出ていない履歴を優先して選び、
    // 表示中の履歴が上限枠を奪われて押し出されないようにする
    private func evictHistories(from all: [FolderHistory], count: Int, context: ModelContext) {
        // 古い順（lastAccessedAt 昇順）に走査する
        let oldestFirst = Array(all.reversed())
        var targets = oldestFirst.filter { unavailableHistoryIDs.contains($0.persistentModelID) }
        if targets.count < count {
            let available = oldestFirst.filter { !unavailableHistoryIDs.contains($0.persistentModelID) }
            targets.append(contentsOf: available.prefix(count - targets.count))
        }
        targets.prefix(count).forEach { context.delete($0) }
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
}
