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
        panel.message = String(localized: "openPanel.folder.message")
        panel.prompt = String(localized: "openPanel.folder.prompt")
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
        await cancelPhotoStaging()
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
            currentFolderURL = url
            currentPhotoSource = .folder(url)
            loadHistories(checkAvailability: false)
            await loadFolderPhotos(url)
        } catch {
            self.error = ShootLogError.bookmarkRestorationFailed
        }
    }

    func loadHistories(checkAvailability: Bool = true) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<FolderHistory>(
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        folderHistories = (try? context.fetch(descriptor)) ?? []
        historyAvailabilityTask?.cancel()
        historyAvailabilityTask = nil
        guard checkAvailability else { return }
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
        await cancelPhotoStaging()
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
            currentPhotoSource = .folder(url)
            loadHistories(checkAvailability: false)
            await loadFolderPhotos(url)
        } catch {
            self.error = ShootLogError.folderAccessDenied
        }
    }

    private func loadFolderPhotos(_ folderURL: URL) async {
        guard let context = modelContext else { return }
        await cancelPhotoStaging()
        isLoading = true
        photos = []
        selectedPhoto = nil
        currentEditInfo = nil
        currentDevelopSettings = nil
        isCropMode = false
        let generation = photoStagingGeneration
        guard applyFileAttributesSnapshots([:], generation: generation) else { return }

        do {
            let scanResult = try await Task.detached(priority: .utility) {
                try PhotoRepository.scanImageURLs(in: folderURL)
            }.value
            let urls = scanResult.urls
            let snapshots = scanResult.snapshots
            guard applyFileAttributesSnapshots(snapshots, generation: generation) else { return }
            syncPhotos(urls: urls, context: context)
            selectPhoto(photos.first)
            let previewGenerationToken = beginPreviewGeneration()
            await PreviewGenerator.shared.start(
                urls: urls,
                snapshots: snapshots,
                around: 0
            ) { [weak self] done, total in
                Task { @MainActor in
                    guard let self else { return }
                    guard previewGenerationToken == self.previewGenerationToken else { return }
                    self.updatePreviewGenerationProgress(done: done, total: total)
                }
            }
            let aiLabelingToken = beginAILabeling()
            let exifPrefetchToken = beginEXIFPrefetch()
            let photoCaptionToken = beginPhotoCaption()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let staging = self.photoStagingTask {
                    await staging.value
                }
                guard aiLabelingToken == self.aiLabelingToken else { return }

                self.resetDetectedAICategories(from: self.photos)
                let targetPhotos = self.photos
                    .filter {
                        $0.aiLabelingFetchedAt == nil
                            || ($0.aiLabelingSchemaVersion ?? 1) < AILabelingGenerator.currentSchemaVersion
                    }
                let photoIndex = Dictionary(
                    uniqueKeysWithValues: self.photos.enumerated().map { ($1.fileURL, $0) }
                )
                let exifURLs = self.photos
                    .filter { $0.phAssetLocalIdentifier == nil && $0.exifFetchedAt == nil }
                    .map(\.fileURL)
                let exifTotal = exifURLs.count
                await EXIFPrefetcher.shared.start(
                    urls: exifURLs,
                    snapshots: snapshots,
                    progress: { [weak self] done, total in
                        Task { @MainActor in
                            guard let self else { return }
                            guard exifPrefetchToken == self.exifPrefetchToken else { return }
                            self.updateEXIFPrefetchProgress(done: done, total: total)
                            // チャンク完了後に結果反映済みのEXIFをまとめて保存する。
                            if exifTotal > 0,
                               done == total || done.isMultiple(of: Self.photoStagingChunkSize) {
                                try? self.modelContext?.save()
                            }
                        }
                    },
                    onResult: { [weak self] url, exif in
                        Task { @MainActor in
                            guard let self else { return }
                            guard exifPrefetchToken == self.exifPrefetchToken else { return }
                            guard let index = photoIndex[url], self.photos.indices.contains(index) else { return }
                            self.apply(exif, to: self.photos[index])
                        }
                    }
                )
                let aiTargets = targetPhotos.map {
                    AILabelingTarget(
                        url: $0.fileURL,
                        localIdentifier: $0.phAssetLocalIdentifier,
                        snapshot: snapshots[$0.fileURL]
                    )
                }
                let aiTotal = aiTargets.count
                await AILabelingGenerator.shared.start(
                    targets: aiTargets,
                    around: 0,
                    progress: { [weak self] done, total in
                        Task { @MainActor in
                            guard let self else { return }
                            guard aiLabelingToken == self.aiLabelingToken else { return }
                            self.updateAILabelingProgress(done: done, total: total)
                        }
                    },
                    onResult: { [weak self] url, result in
                        Task { @MainActor in
                            guard let self else { return }
                            guard aiLabelingToken == self.aiLabelingToken else { return }
                            if let result,
                               let index = photoIndex[url], self.photos.indices.contains(index) {
                                let photo = self.photos[index]
                                photo.aiCategoryRawValues = result.categories.map(\.rawValue)
                                photo.aiRawIdentifiers = result.rawIdentifiers
                                photo.aiLabelingFetchedAt = Date()
                                photo.aiLabelingSchemaVersion = AILabelingGenerator.currentSchemaVersion
                                self.addDetectedAICategories(result.categories)
                            }
                            self.aiLabelingCompletedCount += 1
                            // 書き込み後に保存し、数百〜数千枚の分類ではチャンク単位にI/Oする。
                            if aiTotal > 0,
                               self.aiLabelingCompletedCount == aiTotal
                                || self.aiLabelingCompletedCount.isMultiple(of: Self.photoStagingChunkSize) {
                                try? self.modelContext?.save()
                            }
                        }
                    }
                )
                if #available(macOS 27, *) {
                    let captionURLs = self.photos
                        .filter { $0.aiCaptionFetchedAt == nil }
                        .map(\.fileURL)
                    await PhotoCaptionGenerator.shared.start(
                        urls: captionURLs,
                        around: 0,
                        progress: { [weak self] done, total in
                            Task { @MainActor in
                                guard let self else { return }
                                guard photoCaptionToken == self.photoCaptionToken else { return }
                                // 生成は遅いため、進捗コールバックを保存の区切りにも利用する。
                                if total > 0,
                                   done == total || done.isMultiple(of: Self.photoStagingChunkSize) {
                                    try? self.modelContext?.save()
                                }
                            }
                        },
                        onResult: { [weak self] url, caption in
                            Task { @MainActor in
                                guard let self else { return }
                                guard photoCaptionToken == self.photoCaptionToken else { return }
                                guard let index = photoIndex[url], self.photos.indices.contains(index) else { return }
                                let photo = self.photos[index]
                                photo.aiCaptionText = caption
                                photo.aiCaptionFetchedAt = Date()
                            }
                        }
                    )
                }
            }
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
    func cancelPhotoStaging() async {
        photoStagingTask?.cancel()
        photoStagingTask = nil
        pendingSelectNextTask?.cancel()
        pendingSelectNextTask = nil
        photoStagingGeneration &+= 1
        cancelPreviewGeneration()
        cancelAILabeling()
        cancelEXIFPrefetch()
        cancelPhotoCaption()
        clearDetectedAICategories()
        selectedAICategories.removeAll()
        await PreviewGenerator.shared.cancel()
        await AILabelingGenerator.shared.cancel()
        await EXIFPrefetcher.shared.cancel()
        if #available(macOS 27, *) {
            await PhotoCaptionGenerator.shared.cancel()
        }
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
            loadHistories(checkAvailability: false)
            return
        }

        // 保持件数は「一般」設定タブの値を使う（未設定時は 0 が返るため既定値へフォールバック）
        let storedLimit = UserDefaults.standard.integer(forKey: AppSettingsKeys.folderHistoryLimit)
        let effectiveLimit = storedLimit > 0 ? storedLimit : AppSettingsKeys.folderHistoryLimitDefault
        let overflow = all.count - (effectiveLimit - 1)
        if overflow > 0 { evictHistories(from: all, count: overflow, context: context) }
        context.insert(FolderHistory(url: url, bookmark: bookmark))
        saveOrReportError(context)
        loadHistories(checkAvailability: false)
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

    func releaseBookmarkAccess() {
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
