import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

struct EXIFPrefetcherTests {

    @Test func emptyInputReportsZeroProgress() async {
        let prefetcher = EXIFPrefetcher()
        let progress = EXIFPrefetchProgressRecorder()

        await prefetcher.start(
            urls: [],
            progress: { done, total in
                Task { await progress.record(done: done, total: total) }
            },
            onResult: { _, _ in }
        )

        #expect(await wait { await progress.contains(done: 0, total: 0) })
    }

    @Test func reportsProgressAfterEachStagingSizedChunk() async throws {
        let prefetcher = EXIFPrefetcher()
        let progress = EXIFPrefetchProgressRecorder()
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sourceURL = try writePNG(in: sandbox)
        let urls = Array(repeating: sourceURL, count: 101)

        await prefetcher.start(
            urls: urls,
            progress: { done, total in
                Task { await progress.record(done: done, total: total) }
            },
            onResult: { _, _ in }
        )

        #expect(await wait { await progress.contains(done: urls.count, total: urls.count) })
        #expect(await progress.hasExpectedChunkEvents(total: urls.count))
    }

    @Test func startingAgainCancelsThePreviousBatch() async {
        let firstURLs = makeURLs(count: 200, prefix: "first")
        let secondURLs = makeURLs(count: 3, prefix: "second")
        let reader = RecordingEXIFBatchReader(delay: .milliseconds(100))
        let prefetcher = EXIFPrefetcher(reader: reader)
        let firstResults = EXIFPrefetchResultRecorder()
        let secondResults = EXIFPrefetchResultRecorder()
        let secondProgress = EXIFPrefetchProgressRecorder()

        await prefetcher.start(
            urls: firstURLs,
            progress: { _, _ in },
            onResult: { url, exif in firstResults.record(url: url, exif: exif) }
        )
        #expect(await wait { await reader.requestedCount() > 0 })

        await prefetcher.start(
            urls: secondURLs,
            progress: { done, total in
                Task { await secondProgress.record(done: done, total: total) }
            },
            onResult: { url, exif in secondResults.record(url: url, exif: exif) }
        )

        #expect(await wait { await secondProgress.contains(done: secondURLs.count, total: secondURLs.count) })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(firstResults.count() == 0)
        #expect(secondResults.urls() == Set(secondURLs))
    }

    @Test func cancelPreventsRemainingResults() async {
        let urls = makeURLs(count: 200, prefix: "cancel")
        let reader = RecordingEXIFBatchReader(delay: .milliseconds(100))
        let prefetcher = EXIFPrefetcher(reader: reader)
        let results = EXIFPrefetchResultRecorder()

        await prefetcher.start(
            urls: urls,
            progress: { _, _ in },
            onResult: { url, exif in results.record(url: url, exif: exif) }
        )
        #expect(await wait { results.count() > 0 })

        await prefetcher.cancel()
        let resultCountAtCancellation = results.count()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(resultCountAtCancellation < urls.count)
        #expect(results.count() == resultCountAtCancellation)
    }

    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("EXIFPrefetcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePNG(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source.png")
        let pixels = [UInt8](repeating: 128, count: 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeURLs(count: Int, prefix: String) -> [URL] {
        (0..<count).map { index in
            URL(fileURLWithPath: "/tmp/exif-prefetch-\(prefix)-\(index).jpg")
        }
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
}

private actor EXIFPrefetchProgressRecorder {
    private var recordedEvents: [(Int, Int)] = []

    func record(done: Int, total: Int) {
        recordedEvents.append((done, total))
    }

    func contains(done: Int, total: Int) -> Bool {
        recordedEvents.contains { $0 == (done, total) }
    }

    func hasExpectedChunkEvents(total: Int) -> Bool {
        guard recordedEvents.count == 2 else { return false }
        return recordedEvents[0].0 == 100
            && recordedEvents[0].1 == total
            && recordedEvents[1].0 == total
            && recordedEvents[1].1 == total
    }
}

private actor RecordingEXIFBatchReader: EXIFBatchReading {
    private let delay: Duration?
    private var requests = 0

    init(delay: Duration? = nil) {
        self.delay = delay
    }

    func readEXIFBatch(from urls: [URL], maxConcurrency: Int) async -> [URL: EXIFInfo] {
        requests += 1
        if let delay {
            try? await Task.sleep(for: delay)
        }
        guard !Task.isCancelled else { return [:] }
        return Dictionary(uniqueKeysWithValues: urls.map { ($0, dummyEXIF) })
    }

    func requestedCount() -> Int {
        requests
    }

    private var dummyEXIF: EXIFInfo {
        EXIFInfo(
            cameraMake: nil,
            cameraModel: nil,
            lensModel: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            focalLength: nil,
            shootingDate: nil,
            colorMode: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            fileSizeBytes: nil
        )
    }
}

private final class EXIFPrefetchResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(URL, EXIFInfo)] = []

    func record(url: URL, exif: EXIFInfo) {
        lock.withLock { events.append((url, exif)) }
    }

    func count() -> Int {
        lock.withLock { events.count }
    }

    func urls() -> Set<URL> {
        lock.withLock { Set(events.map(\.0)) }
    }
}
