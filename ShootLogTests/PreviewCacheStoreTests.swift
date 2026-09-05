import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

struct PreviewCacheStoreTests {

    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PreviewCacheStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeColorImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8(20 + (x * 200) / max(width - 1, 1))
                pixels[index + 1] = UInt8(30 + (y * 180) / max(height - 1, 1))
                pixels[index + 2] = 130
                pixels[index + 3] = 255
            }
        }

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

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writePNG(width: Int, height: Int, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        try writePNG(makeColorImage(width: width, height: height), to: url)
        return url
    }

    private func cachedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    @Test func proxyGenerationDownsamplesAndCachesInMemory() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 640, height: 400, in: sandbox)
        let cacheDirectory = sandbox.appendingPathComponent("cache", isDirectory: true)
        let store = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)

        let proxy = try #require(await store.proxy(for: source))
        #expect(max(proxy.width, proxy.height) <= 256)

        let cached = try #require(await store.cachedProxy(for: source))
        #expect(cached.width == proxy.width)
        #expect(cached.height == proxy.height)
    }

    @Test func cachedProxyLoadsFromDiskInNewInstance() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 640, height: 400, in: sandbox)
        let cacheDirectory = sandbox.appendingPathComponent("cache", isDirectory: true)

        let first = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)
        _ = try #require(await first.proxy(for: source))

        let reloaded = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)
        #expect(await reloaded.cachedProxy(for: source) != nil)
    }

    @Test func concurrentGenerationLeavesOneReadableProxyFile() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 640, height: 400, in: sandbox)
        let cacheDirectory = sandbox.appendingPathComponent("cache", isDirectory: true)
        let store = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)

        let proxies = await withTaskGroup(of: CGImage?.self, returning: [CGImage?].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    await store.proxy(for: source)
                }
            }

            var results: [CGImage?] = []
            for await proxy in group {
                results.append(proxy)
            }
            return results
        }

        #expect(proxies.allSatisfy { $0 != nil })
        #expect(try cachedFiles(in: cacheDirectory).count == 1)

        let reloaded = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)
        #expect(await reloaded.cachedProxy(for: source) != nil)
    }

    @Test func sourceModificationInvalidatesPreviousProxyKey() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 640, height: 400, in: sandbox)
        let cacheDirectory = sandbox.appendingPathComponent("cache", isDirectory: true)
        let store = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)
        _ = try #require(await store.proxy(for: source))

        try writePNG(try makeColorImage(width: 800, height: 400), to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)],
            ofItemAtPath: source.path
        )

        #expect(await store.cachedProxy(for: source) == nil)
        let regenerated = try #require(await store.proxy(for: source))
        #expect(max(regenerated.width, regenerated.height) <= 256)
    }

    @Test func storeThenInvalidateRemovesCurrentProxy() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 64, height: 48, in: sandbox)
        let cacheDirectory = sandbox.appendingPathComponent("cache", isDirectory: true)
        let store = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)

        await store.store(try makeColorImage(width: 128, height: 96), for: source)
        #expect(await store.diskUsageBytes() > 0)

        await store.invalidate(source)
        #expect(await store.cachedProxy(for: source) == nil)
        #expect(try cachedFiles(in: cacheDirectory).isEmpty)
    }

    @Test func evictToLimitRemovesOldestFilesFirst() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let cacheDirectory = sandbox.appendingPathComponent("cache", isDirectory: true)
        let writer = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)
        let oldest = try writePNG(width: 64, height: 48, in: sandbox)
        let newest = try writePNG(width: 65, height: 48, in: sandbox)

        await writer.store(try makeColorImage(width: 128, height: 96), for: oldest)
        let oldFile = try #require(cachedFiles(in: cacheDirectory).first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 1)],
            ofItemAtPath: oldFile.path
        )
        await writer.store(try makeColorImage(width: 128, height: 96), for: newest)
        let newFile = try #require(cachedFiles(in: cacheDirectory).first { $0 != oldFile })
        let newSize = try #require(
            newFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 2)],
            ofItemAtPath: newFile.path
        )

        let limitingStore = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: newSize)
        await limitingStore.evictToLimit()
        #expect(await limitingStore.diskUsageBytes() <= newSize)

        let reloaded = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)
        #expect(await reloaded.cachedProxy(for: oldest) == nil)
        #expect(await reloaded.cachedProxy(for: newest) != nil)
    }

    @Test func corruptedCacheFileReturnsNilWithoutCrashing() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 64, height: 48, in: sandbox)
        let cacheDirectory = sandbox.appendingPathComponent("cache", isDirectory: true)
        let writer = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)
        _ = try #require(await writer.proxy(for: source))

        let file = try #require(cachedFiles(in: cacheDirectory).first)
        try Data([0x00, 0x01, 0x02]).write(to: file)

        let reloaded = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)
        #expect(await reloaded.cachedProxy(for: source) == nil)
    }

    @Test func clearAllRemovesEveryCacheFile() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 64, height: 48, in: sandbox)
        let cacheDirectory = sandbox.appendingPathComponent("cache", isDirectory: true)
        let store = PreviewCacheStore(directory: cacheDirectory, proxyLongEdge: 256, maxDiskBytes: .max)
        _ = try #require(await store.proxy(for: source))

        await store.clearAll()
        #expect(try cachedFiles(in: cacheDirectory).isEmpty)
    }

    @Test func dataWriteAtomicallyCreatesAndReplacesDestination() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let destination = sandbox.appendingPathComponent("asset.jpg")

        #expect(ImageFileCache.writeData(Data([1, 2, 3]), to: destination))
        #expect(try Data(contentsOf: destination) == Data([1, 2, 3]))
        #expect(ImageFileCache.writeData(Data([4, 5, 6]), to: destination))
        #expect(try Data(contentsOf: destination) == Data([4, 5, 6]))
        #expect(try cachedFiles(in: sandbox).count == 1)
    }

    @Test func prepareSupportsCustomTemporaryFileNames() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let hashTemporary = sandbox.appendingPathComponent(
            "\(String(repeating: "a", count: 64)).\(UUID().uuidString).jpg"
        )
        let assetTemporary = sandbox.appendingPathComponent(
            "asset.identifier.\(UUID().uuidString).jpg"
        )
        try Data().write(to: hashTemporary)
        try Data().write(to: assetTemporary)

        ImageFileCache.prepare(directory: sandbox, extensions: ["jpg"])
        #expect(FileManager.default.fileExists(atPath: hashTemporary.path) == false)
        #expect(FileManager.default.fileExists(atPath: assetTemporary.path))

        ImageFileCache.prepare(
            directory: sandbox,
            extensions: ["jpg"],
            isTemporaryFile: { url in url.lastPathComponent == assetTemporary.lastPathComponent }
        )
        #expect(FileManager.default.fileExists(atPath: assetTemporary.path) == false)
    }
}
