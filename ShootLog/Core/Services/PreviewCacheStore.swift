import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

protocol PreviewProxyProviding: Sendable {
    func generate(for url: URL) async -> Bool
    func cachedProxy(for url: URL) async -> CGImage?
    func evictToLimit() async
}

/// ビューア用の固定解像度プレビューを、原本の更新に追従するディスクキャッシュとして管理する。
final class PreviewCacheStore: PreviewProxyProviding, Sendable {
    static let shared = PreviewCacheStore()

    static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.shootlog.app/previews-v1", isDirectory: true)
    }()

    // UserDefaults.integer(forKey:) は未設定時に 0 を返すため、既定値へフォールバックする。
    static let storedProxyLongEdge: Int = {
        let stored = UserDefaults.standard.integer(forKey: AppSettingsKeys.previewProxyLongEdge)
        return stored > 0 ? stored : AppSettingsKeys.previewProxyLongEdgeDefault
    }()

    // UserDefaults.integer(forKey:) は未設定時に 0 を返すため、既定値へフォールバックする。
    static let storedMaxDiskBytes: Int = {
        let stored = UserDefaults.standard.integer(forKey: AppSettingsKeys.previewCacheMaxBytes)
        return stored > 0 ? stored : AppSettingsKeys.previewCacheMaxBytesDefault
    }()

    // NSCache はスレッドセーフ。nonisolated(unsafe) で Swift 6 の Sendable チェックを回避する。
    nonisolated(unsafe) private let memoryCache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 32
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()

    let proxyLongEdge: Int
    private let directory: URL
    private let maxDiskBytes: Int
    private let decodeThrottle = DecodeThrottle(
        maxConcurrent: max(2, ProcessInfo.processInfo.activeProcessorCount)
    )

    init(
        directory: URL = PreviewCacheStore.defaultDirectory,
        proxyLongEdge: Int = PreviewCacheStore.storedProxyLongEdge,
        maxDiskBytes: Int = PreviewCacheStore.storedMaxDiskBytes
    ) {
        self.directory = directory
        self.proxyLongEdge = max(1, proxyLongEdge)
        self.maxDiskBytes = max(0, maxDiskBytes)
    }

    /// メモリ、次にディスクから既存のプロキシを読み込む。キャッシュミス時は生成しない。
    func cachedProxy(for url: URL) async -> CGImage? {
        let key = await cacheKey(for: url)
        return await cachedProxy(forKey: key)
    }

    /// 既存プロキシを返し、無い場合は固定解像度へダウンサンプルして保存する。
    func proxy(for url: URL) async -> CGImage? {
        let key = await cacheKey(for: url)
        if let cached = await cachedProxy(forKey: key) {
            return cached
        }

        guard !Task.isCancelled,
              let image = await decodeProxy(for: url) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        _ = await store(image, forKey: key, evictAfter: true)
        return image
    }

    /// バックグラウンド生成用。既存プロキシを再デコードせず、バッチ側でまとめてevictionできるようにする。
    func generate(for url: URL) async -> Bool {
        let key = await cacheKey(for: url)
        if await cachedProxy(forKey: key) != nil { return true }
        guard !Task.isCancelled,
              let image = await decodeProxy(for: url),
              !Task.isCancelled else {
            return false
        }

        return await store(image, forKey: key, evictAfter: false) && !Task.isCancelled
    }

    /// 後続のバックグラウンド生成処理からも使えるよう、生成済み画像を保存する。
    func store(_ image: CGImage, for url: URL) async {
        let key = await cacheKey(for: url)
        _ = await store(image, forKey: key, evictAfter: true)
    }

    /// キャッシュディレクトリ内のファイル使用量を返す。
    func diskUsageBytes() async -> Int {
        await diskEntries().reduce(0) { $0 + $1.size }
    }

    /// 上限を超えた分を、最終更新日時が古いファイルから削除する。
    func evictToLimit() async {
        let entries = await diskEntries().sorted { $0.modificationDate < $1.modificationDate }
        var usage = entries.reduce(0) { $0 + $1.size }
        var filesToRemove: [URL] = []
        for entry in entries where usage > maxDiskBytes {
            filesToRemove.append(entry.url)
            usage -= entry.size
        }
        await Task.detached(priority: .utility) {
            for fileURL in filesToRemove {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }.value
    }

    /// 指定原本の現在のバージョンに対応するプロキシを削除する。
    func invalidate(_ url: URL) async {
        let key = await cacheKey(for: url)
        memoryCache.removeObject(forKey: key as NSString)
        await removeDiskFiles(forKey: key)
    }

    /// 設定画面の明示操作用にすべてのプロキシを削除する。
    func clearAll() async {
        memoryCache.removeAllObjects()
        await Task.detached(priority: .utility) { [directory] in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return }
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }.value
    }

    /// 起動時にキャッシュディレクトリを用意し、古いエントリを上限まで削除する。
    func warmUp() async {
        await Task.detached(priority: .utility) { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.removeInterruptedWriteFiles(in: directory)
        }.value
        await evictToLimit()
    }

    private func cachedProxy(forKey key: String) async -> CGImage? {
        if let cached = memoryCache.object(forKey: key as NSString) {
            touchDiskProxy(forKey: key)
            return cached.image
        }

        guard let image = await readDiskProxy(forKey: key) else { return nil }
        memoryCache.setObject(CGImageBox(image), forKey: key as NSString, cost: estimatedCost(of: image))
        return image
    }

    private func store(_ image: CGImage, forKey key: String, evictAfter: Bool) async -> Bool {
        guard await writeDiskProxy(image, forKey: key) else { return false }
        memoryCache.setObject(CGImageBox(image), forKey: key as NSString, cost: estimatedCost(of: image))
        if evictAfter {
            await evictToLimit()
        }
        return true
    }

    private func cacheKey(for url: URL) async -> String {
        await Task.detached(priority: .utility) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modificationDate = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let source = "\(url.absoluteString)|\(modificationDate)|\(fileSize)"
            return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private func decodeProxy(for url: URL) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        do {
            try await decodeThrottle.acquire()
        } catch {
            return nil
        }
        guard !Task.isCancelled else {
            await decodeThrottle.release()
            return nil
        }

        let proxyLongEdge = proxyLongEdge
        let task: Task<CGImage?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return nil as CGImage?
            }
            return Self.decodeDownsampled(source: source, maxPixelSize: proxyLongEdge)
        }
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        await decodeThrottle.release()
        return image
    }

    private func readDiskProxy(forKey key: String) async -> CGImage? {
        let directory = directory
        let task: Task<CGImage?, Never> = Task.detached(priority: .utility) {
            for fileURL in Self.diskURLs(forKey: key, in: directory) {
                guard !Task.isCancelled else { return nil }
                guard FileManager.default.fileExists(atPath: fileURL.path),
                      let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continue
                }
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
                return image
            }
            return nil as CGImage?
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func writeDiskProxy(_ image: CGImage, forKey key: String) async -> Bool {
        let directory = directory
        let task: Task<Bool, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return false }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return false
            }
            if Self.write(image, type: "public.heic" as CFString, to: Self.diskURL(forKey: key, extension: "heic", in: directory)) {
                try? FileManager.default.removeItem(at: Self.diskURL(forKey: key, extension: "jpg", in: directory))
                return true
            } else if Self.write(image, type: "public.jpeg" as CFString, to: Self.diskURL(forKey: key, extension: "jpg", in: directory)) {
                try? FileManager.default.removeItem(at: Self.diskURL(forKey: key, extension: "heic", in: directory))
                return true
            }
            return false
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func removeDiskFiles(forKey key: String) async {
        let directory = directory
        await Task.detached(priority: .utility) {
            for fileURL in Self.diskURLs(forKey: key, in: directory) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }.value
    }

    private func touchDiskProxy(forKey key: String) {
        let directory = directory
        Task.detached(priority: .utility) {
            for fileURL in Self.diskURLs(forKey: key, in: directory)
            where FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
                return
            }
        }
    }

    private func diskEntries() async -> [DiskEntry] {
        let directory = directory
        return await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys)
            ) else { return [] }
            return files.compactMap { fileURL in
                guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else {
                    return nil
                }
                return DiskEntry(
                    url: fileURL,
                    size: values.fileSize ?? 0,
                    modificationDate: values.contentModificationDate ?? .distantPast
                )
            }
        }.value
    }

    private static func decodeDownsampled(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let embeddedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]
        if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions as CFDictionary),
           CGFloat(max(embedded.width, embedded.height)) >= CGFloat(maxPixelSize) * 0.9 {
            return embedded
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary)
    }

    private static func write(_ image: CGImage, type: CFString, to url: URL) -> Bool {
        let temporaryURL = url.deletingPathExtension()
            .appendingPathExtension("\(UUID().uuidString).\(url.pathExtension)")
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, type, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporaryURL)
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
        // 同一キーを並行生成した別タスクが先に置換していれば、その完成済みプロキシを採用する。
        return fileManager.fileExists(atPath: url.path)
    }

    private static func diskURLs(forKey key: String, in directory: URL) -> [URL] {
        [
            diskURL(forKey: key, extension: "heic", in: directory),
            diskURL(forKey: key, extension: "jpg", in: directory)
        ]
    }

    private static func diskURL(forKey key: String, extension fileExtension: String, in directory: URL) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension(fileExtension)
    }

    private static func removeInterruptedWriteFiles(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in files where isInterruptedWriteFile(fileURL) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func isInterruptedWriteFile(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "heic" || fileExtension == "jpg" else { return false }

        let components = url.deletingPathExtension().lastPathComponent.split(separator: ".")
        guard components.count == 2,
              components[0].count == 64,
              components[0].allSatisfy({ $0.isHexDigit }),
              UUID(uuidString: String(components[1])) != nil else {
            return false
        }
        return true
    }

    private func estimatedCost(of image: CGImage) -> Int {
        max(1, image.width * image.height * 4)
    }
}

// プロキシ生成はビューアの対話要求とバックグラウンド生成で同じ枠を共有する。
private actor DecodeThrottle {
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async throws {
        guard active >= maxConcurrent else {
            active += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    func release() {
        if let (id, continuation) = waiters.first {
            waiters.removeValue(forKey: id)
            continuation.resume()
        } else {
            active -= 1
        }
    }
}

private final class CGImageBox {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private struct DiskEntry: Sendable {
    let url: URL
    let size: Int
    let modificationDate: Date
}
