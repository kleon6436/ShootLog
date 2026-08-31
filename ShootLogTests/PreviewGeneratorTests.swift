import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

struct PreviewGeneratorTests {

    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PreviewGeneratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeColorImage() throws -> CGImage {
        let width = 64
        let height = 48
        let pixels = [UInt8](repeating: 128, count: width * height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func writePNG(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try makeColorImage(), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func wait(
        until condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func generatesEveryProxyAndReportsCompletion() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let urls = try (0..<4).map { _ in try writePNG(in: sandbox) }
        let store = PreviewCacheStore(
            directory: sandbox.appendingPathComponent("cache", isDirectory: true),
            proxyLongEdge: 128,
            maxDiskBytes: .max
        )
        let generator = PreviewGenerator(store: store)
        let progress = ProgressRecorder()

        await generator.start(urls: urls, around: nil) { done, total in
            progress.record(done: done, total: total)
        }

        #expect(await wait { progress.didFinish(total: urls.count) })
        for url in urls {
            #expect(await store.cachedProxy(for: url) != nil)
        }
        #expect(progress.maxDone() == urls.count)
    }

    @Test func prioritizesSelectedIndexBeforeOtherURLs() async {
        let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/preview-generator-\($0).png") }
        let store = RecordingPreviewStore()
        let generator = PreviewGenerator(store: store)
        let progress = ProgressRecorder()

        await generator.start(urls: urls, around: 2) { done, total in
            progress.record(done: done, total: total)
        }

        #expect(await wait { progress.didFinish(total: urls.count) })
        #expect(await store.generatedURLs().first == urls[2])
    }

    @Test func cancelLeavesURLsUngenerated() async {
        let urls = (0..<200).map { URL(fileURLWithPath: "/tmp/preview-generator-cancel-\($0).png") }
        let store = RecordingPreviewStore(delay: .milliseconds(100))
        let generator = PreviewGenerator(store: store)

        await generator.start(urls: urls, around: nil) { _, _ in }
        #expect(await wait { await store.generatedURLs().count == 1 })
        await generator.cancel()
        let generatedAtCancellation = await store.generatedURLs().count
        try? await Task.sleep(for: .milliseconds(100))

        #expect(generatedAtCancellation < urls.count)
        #expect(await store.generatedURLs().count == generatedAtCancellation)
    }

    @Test func existingProxiesDoNotGenerateAgain() async {
        let urls = (0..<4).map { URL(fileURLWithPath: "/tmp/preview-generator-cached-\($0).png") }
        let store = RecordingPreviewStore(cachedURLs: Set(urls))
        let generator = PreviewGenerator(store: store)
        let progress = ProgressRecorder()

        await generator.start(urls: urls, around: nil) { done, total in
            progress.record(done: done, total: total)
        }

        #expect(await wait { progress.didFinish(total: urls.count) })
        #expect(await store.generatedURLs().isEmpty)
    }
}

// 進捗コールバックは複数タスクから同期的に呼ばれ、順序保証が無い。
// events.last での判定は不安定なので「(total, total) を一度でも観測したか」で判定する。
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Int, Int)] = []

    func record(done: Int, total: Int) {
        lock.withLock { events.append((done, total)) }
    }

    func didFinish(total: Int) -> Bool {
        lock.withLock { events.contains { $0 == (total, total) } }
    }

    func maxDone() -> Int {
        lock.withLock { events.map(\.0).max() ?? 0 }
    }
}

private actor RecordingPreviewStore: PreviewProxyProviding {
    private let delay: Duration?
    private var cachedURLs: Set<URL>
    private var generated: [URL] = []

    init(delay: Duration? = nil, cachedURLs: Set<URL> = []) {
        self.delay = delay
        self.cachedURLs = cachedURLs
    }

    func generate(for url: URL) async -> Bool {
        if cachedURLs.contains(url) { return true }
        generated.append(url)
        if let delay {
            try? await Task.sleep(for: delay)
        }
        guard !Task.isCancelled else { return false }
        cachedURLs.insert(url)
        return true
    }

    func cachedProxy(for url: URL) async -> CGImage? {
        nil
    }

    func evictToLimit() async {}

    func generatedURLs() -> [URL] {
        generated
    }
}
