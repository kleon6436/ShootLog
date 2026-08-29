import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

struct ImageDevelopmentEngineTests {

    // MARK: - ヘルパー

    /// テストごとに独立した作業ディレクトリを作る（`UpscaleExporterTests` と同じ方式）。
    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ImageDevelopmentEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// R/G が位置で変化し B が一定の、決定論的なカラー画像。
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

    @discardableResult
    private func writePNG(width: Int, height: Int, in sandbox: URL) throws -> URL {
        let image = try makeColorImage(width: width, height: height)
        let url = sandbox.appendingPathComponent("\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// CGImage を sRGB の RGBA8 バイト列へ展開する。
    private func rgbaBytes(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)

        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        return buffer
    }

    /// チャンネルごとの平均値（R, G, B）。
    private func meanChannels(of image: CGImage) throws -> (red: Double, green: Double, blue: Double) {
        let pixels = try rgbaBytes(of: image)
        var totals = (0.0, 0.0, 0.0)
        var count = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            totals.0 += Double(pixels[index])
            totals.1 += Double(pixels[index + 1])
            totals.2 += Double(pixels[index + 2])
            count += 1
        }
        guard count > 0 else { return (0, 0, 0) }
        return (totals.0 / count, totals.1 / count, totals.2 / count)
    }

    private func meanLuma(of image: CGImage) throws -> Double {
        let channels = try meanChannels(of: image)
        return (channels.red + channels.green + channels.blue) / 3
    }

    // MARK: - RAW 判定

    @Test func rawExtensionsAreDetectedCaseInsensitively() {
        let engine = ImageDevelopmentEngine()
        let base = URL(fileURLWithPath: "/tmp/sample")

        for ext in ["NEF", "dng", "Arw", "cr3", "RAF"] {
            #expect(engine.isRAW(url: base.appendingPathExtension(ext)))
        }
        for ext in ["jpg", "JPEG", "png", "heic", "tiff"] {
            #expect(engine.isRAW(url: base.appendingPathExtension(ext)) == false)
        }
    }

    // MARK: - プレビュー

    @Test func neutralPreviewKeepsSourceDimensionsWhenSmallerThanTarget() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = ImageDevelopmentEngine()

        let preview = try #require(
            await engine.renderPreview(url: url, parameters: .neutral, targetMaxPixelSize: 256)
        )
        // 拡大はしないため、原本より小さい要求でも原寸のまま返る。
        #expect(preview.width == 128)
        #expect(preview.height == 96)
    }

    @Test func previewDownscalesLargeSourceAndKeepsAspectRatio() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 600, height: 400, in: sandbox)
        let engine = ImageDevelopmentEngine()

        let preview = try #require(
            await engine.renderPreview(url: url, parameters: .neutral, targetMaxPixelSize: 256)
        )
        // 要求値は 512px 刻みのバケットへ切り上げられるため、長辺は概ね 512px になる。
        let longest = max(preview.width, preview.height)
        #expect(longest <= 514)
        #expect(longest >= 500)

        let sourceAspect = 600.0 / 400.0
        let previewAspect = Double(preview.width) / Double(preview.height)
        #expect(abs(previewAspect - sourceAspect) < 0.05)
    }

    @Test func neutralPreviewPreservesSourceColors() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = ImageDevelopmentEngine()

        let source = try makeColorImage(width: 128, height: 96)
        let preview = try #require(
            await engine.renderPreview(url: url, parameters: .neutral, targetMaxPixelSize: 256)
        )

        let expected = try meanChannels(of: source)
        let actual = try meanChannels(of: preview)
        #expect(abs(actual.red - expected.red) < 3)
        #expect(abs(actual.green - expected.green) < 3)
        #expect(abs(actual.blue - expected.blue) < 3)
    }

    @Test func positiveExposureBrightensPreview() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = ImageDevelopmentEngine()

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1.0

        let neutral = try #require(
            await engine.renderPreview(url: url, parameters: .neutral, targetMaxPixelSize: 256)
        )
        let brightened = try #require(
            await engine.renderPreview(url: url, parameters: parameters, targetMaxPixelSize: 256)
        )
        #expect(try meanLuma(of: brightened) > meanLuma(of: neutral))
    }

    @Test func repeatedPreviewRequestsAreConsistent() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = ImageDevelopmentEngine()

        var parameters = DevelopParameters.neutral
        parameters.contrast = 40

        let first = try #require(
            await engine.renderPreview(url: url, parameters: parameters, targetMaxPixelSize: 256)
        )
        let second = try #require(
            await engine.renderPreview(url: url, parameters: parameters, targetMaxPixelSize: 256)
        )

        #expect(first.width == second.width)
        #expect(first.height == second.height)
        #expect(try rgbaBytes(of: first) == rgbaBytes(of: second))
    }

    // MARK: - フル解像度

    @Test func renderFullKeepsSourceDimensions() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = ImageDevelopmentEngine()

        let full = try #require(await engine.renderFull(url: url, parameters: .neutral))
        #expect(full.width == 128)
        #expect(full.height == 96)
    }

    @Test func renderFullAppliesAdjustments() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = ImageDevelopmentEngine()

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1.0

        let neutral = try #require(await engine.renderFull(url: url, parameters: .neutral))
        let brightened = try #require(await engine.renderFull(url: url, parameters: parameters))
        #expect(try meanLuma(of: brightened) > meanLuma(of: neutral))
    }

    // MARK: - 失敗系

    @Test func missingFileReturnsNilInsteadOfCrashing() async throws {
        let sandbox = try makeSandbox()
        let missing = sandbox.appendingPathComponent("does-not-exist.png")
        let engine = ImageDevelopmentEngine()

        #expect(await engine.renderPreview(
            url: missing, parameters: .neutral, targetMaxPixelSize: 256
        ) == nil)
        #expect(await engine.renderFull(url: missing, parameters: .neutral) == nil)
    }
}
