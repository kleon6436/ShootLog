import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Photos Libraryのアセットを既存のURLベース処理へ渡すためのエクスポーター。
actor PhotosLibraryAssetExporter {
    static let shared = PhotosLibraryAssetExporter()

    private static let evictionInterval = 100

    nonisolated static let defaultDirectory: URL = {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return cachesDirectory.appendingPathComponent(
            "com.shootlog.app/icloud-import-v2",
            isDirectory: true
        )
    }()

    nonisolated static let defaultMaxDiskBytes = 2 * 1024 * 1024 * 1024

    private var inFlightTasks: [String: (fileURL: URL, task: Task<Void, Never>)] = [:]
    private var exportsSinceEviction = 0

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

        if let inFlightTask = inFlightTasks[localIdentifier], inFlightTask.fileURL == fileURL {
            await inFlightTask.task.value
            return
        }

        let task = Task { [localIdentifier, fileURL] in
            await self.exportAsset(localIdentifier: localIdentifier, to: fileURL)
        }
        inFlightTasks[localIdentifier] = (fileURL: fileURL, task: task)
        await task.value
        if inFlightTasks[localIdentifier]?.fileURL == fileURL {
            inFlightTasks[localIdentifier] = nil
        }
    }

    /// 起動時にエクスポートキャッシュを準備し、古いファイルを上限内へ整理する。
    func warmUp() async {
        let directory = directory
        exportsSinceEviction = 0
        await Task.detached(priority: .utility) {
            ImageFileCache.prepare(
                directory: directory,
                extensions: ["jpg"],
                isTemporaryFile: Self.isTemporaryExportFile
            )
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

        let maxPixelSize = PreviewCacheStore.shared.proxyLongEdge
        let exportData = Self.resizedJPEGData(from: data, maxPixelSize: maxPixelSize) ?? data
        guard ImageFileCache.writeData(exportData, to: fileURL) else { return }

        exportsSinceEviction += 1
        if exportsSinceEviction.isMultiple(of: Self.evictionInterval) {
            exportsSinceEviction = 0
            await evictToLimit()
        }
    }

    private func requestImageData(
        for asset: PHAsset,
        options: PHImageRequestOptions
    ) async -> Data? {
        let state = PHImageManagerRequestState<Data>()
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

    private static func resizedJPEGData(from data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // kCGImageSourceCreateThumbnailWithTransformでピクセルを正立化するため、
        // 元のorientationタグを引き継ぐと二重回転扱いになる。書き出す側は除去する。
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        properties?[kCGImagePropertyOrientation] = nil
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
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

    static let isTemporaryExportFile: @Sendable (URL) -> Bool = { url in
        guard url.pathExtension.caseInsensitiveCompare("jpg") == .orderedSame else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        guard let separator = name.lastIndex(of: "."), separator != name.startIndex else { return false }
        let uuid = name[name.index(after: separator)...]
        return UUID(uuidString: String(uuid)) != nil
    }
}
