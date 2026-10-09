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

    /// 同一アセットへ進行中のエクスポート。`waiterIDs` は結果を待っている呼び出し元で、
    /// 全員がキャンセルしたらエクスポート自体（PHImageManager のダウンロードを含む）を中止する。
    private struct InFlightExport {
        let token: UUID
        let fileURL: URL
        let task: Task<Bool, Never>
        var waiterIDs: Set<UUID>
    }

    private var inFlightTasks: [String: InFlightExport] = [:]
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
    // 待機中の呼び出し元が全員キャンセルした場合は、共有のエクスポートタスクもキャンセルする
    // （写真を素早く切り替えた際に、不要になったiCloudダウンロードを走らせ続けない）。
    // 一部の呼び出し元だけがキャンセルした場合は、残りの呼び出し元のためにエクスポートを継続する。
    @discardableResult
    func ensureExported(localIdentifier: String, fileURL: URL) async -> Bool {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // キャッシュヒット時も更新日時を進め、mtime昇順のevictionで
            // よく閲覧される写真から先に消えないようにする（LRU化）。
            ImageFileCache.touch(fileURL)
            return true
        }

        let waiterID = UUID()
        let export: InFlightExport
        if var existing = inFlightTasks[localIdentifier], existing.fileURL == fileURL {
            existing.waiterIDs.insert(waiterID)
            inFlightTasks[localIdentifier] = existing
            export = existing
        } else {
            let task = Task { [localIdentifier, fileURL] in
                await self.exportAsset(localIdentifier: localIdentifier, to: fileURL)
            }
            export = InFlightExport(token: UUID(), fileURL: fileURL, task: task, waiterIDs: [waiterID])
            inFlightTasks[localIdentifier] = export
        }

        let token = export.token
        let result = await withTaskCancellationHandler {
            await export.task.value
        } onCancel: {
            Task { await self.removeWaiter(waiterID, localIdentifier: localIdentifier, token: token) }
        }

        if inFlightTasks[localIdentifier]?.token == token {
            inFlightTasks[localIdentifier] = nil
        }
        return result && FileManager.default.fileExists(atPath: fileURL.path)
    }

    // キャンセルした呼び出し元を待機者から外し、誰も待っていなければエクスポートを中止する。
    // 中止したエントリは即座に外し、後から来た要求がキャンセル済みタスクへ合流しないようにする
    private func removeWaiter(_ waiterID: UUID, localIdentifier: String, token: UUID) {
        guard var export = inFlightTasks[localIdentifier], export.token == token else { return }
        export.waiterIDs.remove(waiterID)
        if export.waiterIDs.isEmpty {
            inFlightTasks[localIdentifier] = nil
            export.task.cancel()
        } else {
            inFlightTasks[localIdentifier] = export
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

    private func exportAsset(localIdentifier: String, to fileURL: URL) async -> Bool {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject else { return false }

        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        guard let data = await requestImageData(for: asset, options: options),
              !Task.isCancelled else {
            return false
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }

        let maxPixelSize = PreviewCacheStore.shared.proxyLongEdge
        let exportData = Self.resizedJPEGData(from: data, maxPixelSize: maxPixelSize) ?? data
        guard ImageFileCache.writeData(exportData, to: fileURL) else { return false }

        exportsSinceEviction += 1
        if exportsSinceEviction.isMultiple(of: Self.evictionInterval) {
            exportsSinceEviction = 0
            await evictToLimit()
        }
        return true
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
        // 元のorientationタグを引き継ぐと二重回転扱いになる。書き出す側は正立（1）へ揃える。
        // トップレベルだけでなく {TIFF} 辞書の Orientation も書き出されるため、両方を正規化する。
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        properties?[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        if var tiffProperties = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiffProperties[kCGImagePropertyTIFFOrientation] = CGImagePropertyOrientation.up.rawValue
            properties?[kCGImagePropertyTIFFDictionary] = tiffProperties
        }
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
