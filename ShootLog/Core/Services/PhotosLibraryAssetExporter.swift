import Foundation
import Photos

/// Photos Libraryのアセットを既存のURLベース処理へ渡すためのエクスポーター。
actor PhotosLibraryAssetExporter {
    static let shared = PhotosLibraryAssetExporter()

    nonisolated static let defaultDirectory: URL = {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return cachesDirectory.appendingPathComponent(
            "com.shootlog.app/icloud-import-v1",
            isDirectory: true
        )
    }()

    nonisolated static let defaultMaxDiskBytes = 2 * 1024 * 1024 * 1024

    private var inFlightTasks: [String: Task<Void, Never>] = [:]

    private let directory: URL
    private let maxDiskBytes: Int

    init(
        directory: URL = PhotosLibraryAssetExporter.defaultDirectory,
        maxDiskBytes: Int = PhotosLibraryAssetExporter.defaultMaxDiskBytes
    ) {
        self.directory = directory
        self.maxDiskBytes = max(0, maxDiskBytes)
    }

    nonisolated static func fileURL(forLocalIdentifier localIdentifier: String) -> URL {
        defaultDirectory.appendingPathComponent(sanitizedAssetFileName(localIdentifier))
    }

    // 同じアセットへの要求をまとめ、PhotoImageViewModelとEXIF取得の二重取得を防ぐ。
    func ensureExported(localIdentifier: String, fileURL: URL) async {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        if let task = inFlightTasks[localIdentifier] {
            await task.value
            return
        }

        let task = Task { [localIdentifier, fileURL] in
            await self.exportAsset(localIdentifier: localIdentifier, to: fileURL)
        }
        inFlightTasks[localIdentifier] = task
        await task.value
        inFlightTasks[localIdentifier] = nil
    }

    /// 起動時にエクスポートキャッシュを準備し、古いファイルを上限内へ整理する。
    func warmUp() async {
        let directory = directory
        await Task.detached(priority: .utility) {
            ImageFileCache.prepare(directory: directory, extensions: ["jpg"])
        }.value
        await evictToLimit()
    }

    /// エクスポートキャッシュを最終更新日時の古い順に上限まで削除する。
    func evictToLimit() async {
        let directory = directory
        let maxDiskBytes = maxDiskBytes
        await Task.detached(priority: .utility) {
            ImageFileCache.evict(in: directory, maxBytes: maxDiskBytes)
        }.value
    }

    /// 設定画面のキャッシュ削除操作でエクスポート済みファイルをすべて削除する。
    func clearAll() async {
        let directory = directory
        await Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return }
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }.value
    }

    private func exportAsset(localIdentifier: String, to fileURL: URL) async {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject else { return }

        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        guard let data = await requestImageData(for: asset, options: options),
              !Task.isCancelled else {
            return
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return
        }

        let didWrite = Self.writeDataAtomically(data, to: fileURL)
        if didWrite {
            await evictToLimit()
        }
    }

    private func requestImageData(
        for asset: PHAsset,
        options: PHImageRequestOptions
    ) async -> Data? {
        let state = PhotosLibraryExportRequestState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.setContinuation(continuation)
                let requestID = PHImageManager.default().requestImageDataAndOrientation(
                    for: asset,
                    options: options
                ) { data, _, _, _ in
                    _ = state.finish(data)
                }
                state.setRequestID(requestID)
            }
        } onCancel: {
            state.cancel()
        }
    }

    private static func writeDataAtomically(_ data: Data, to url: URL) -> Bool {
        let temporaryURL = url.deletingPathExtension()
            .appendingPathExtension("\(UUID().uuidString).\(url.pathExtension)")
        do {
            try data.write(to: temporaryURL)
        } catch {
            return false
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            if (try? fileManager.replaceItemAt(url, withItemAt: temporaryURL)) != nil {
                return true
            }
        } else if (try? fileManager.moveItem(at: temporaryURL, to: url)) != nil {
            return true
        }

        try? fileManager.removeItem(at: temporaryURL)
        // 同一アセットの別タスクが先に書き込んでいれば、その完成済みデータを採用する。
        return fileManager.fileExists(atPath: url.path)
    }
}

private extension PhotosLibraryAssetExporter {
    static func sanitizedAssetFileName(_ localIdentifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = localIdentifier.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }
        return String(sanitized) + ".jpg"
    }
}

private final class PhotosLibraryExportRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private(set) var requestID: PHImageRequestID?
    private var continuation: CheckedContinuation<Data?, Never>?

    func setContinuation(_ continuation: CheckedContinuation<Data?, Never>) {
        lock.lock()
        self.continuation = continuation
        let shouldCancel = isFinished
        lock.unlock()
        if shouldCancel { continuation.resume(returning: nil) }
    }

    func setRequestID(_ requestID: PHImageRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(requestID) }
    }

    func finish(_ data: Data?) -> Bool {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return false
        }
        isFinished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: data)
        return true
    }

    func cancel() {
        lock.lock()
        let requestID = self.requestID
        let continuation = self.continuation
        self.continuation = nil
        isFinished = true
        lock.unlock()
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        continuation?.resume(returning: nil)
    }
}
