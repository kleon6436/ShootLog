import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

struct UpscaleExporterTests {

    private static let imageSide = 256

    /// テストごとに独立した作業ディレクトリを作る
    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("UpscaleExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 決定論的な疑似ノイズ画像。単色やなだらかなグラデーションでは
    /// 品質を下げてもJPEGのサイズがほとんど変わらず、単調性を検証できないため
    private func makeNoiseImage() throws -> CGImage {
        let side = Self.imageSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0x9E37_79B9
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 16)
            pixels[index + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            pixels[index + 2] = UInt8(truncatingIfNeeded: seed)
            pixels[index + 3] = 255
        }

        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func encodedSize(
        _ image: CGImage,
        contentType: UTType,
        jpegQuality: Double,
        in sandbox: URL
    ) async throws -> Int {
        let url = sandbox.appendingPathComponent("\(UUID().uuidString).out")
        try await UpscaleExporter.encode(
            image,
            to: url,
            contentType: contentType,
            modelID: "test",
            isTrainedAlgorithmicMedia: false,
            jpegQuality: jpegQuality
        )
        return try Data(contentsOf: url).count
    }

    private func encodedData(
        _ image: CGImage,
        contentType: UTType,
        jpegQuality: Double,
        in sandbox: URL
    ) async throws -> Data {
        let url = sandbox.appendingPathComponent("\(UUID().uuidString).out")
        try await UpscaleExporter.encode(
            image,
            to: url,
            contentType: contentType,
            modelID: "test",
            isTrainedAlgorithmicMedia: false,
            jpegQuality: jpegQuality
        )
        return try Data(contentsOf: url)
    }

    // MARK: - JPEG

    @Test func jpegSizeDecreasesMonotonicallyWithQuality() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let image = try makeNoiseImage()

        var sizes: [Int] = []
        for quality in UpscaleExportViewModel.JPEGQuality.allCases {
            sizes.append(try await encodedSize(
                image, contentType: .jpeg, jpegQuality: quality.rawValue, in: sandbox
            ))
        }

        #expect(sizes.count == 4)
        for (larger, smaller) in zip(sizes, sizes.dropFirst()) {
            #expect(larger >= smaller)
        }
        // 最高と最低で実際に差が出ることまで確認する（全て同値なら品質が効いていない）
        let first = try #require(sizes.first)
        let last = try #require(sizes.last)
        #expect(first > last)
    }

    // MARK: - 可逆形式

    @Test func tiffOutputIsUnaffectedByJPEGQuality() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let image = try makeNoiseImage()

        let highest = try await encodedData(image, contentType: .tiff, jpegQuality: 1.0, in: sandbox)
        let low = try await encodedData(image, contentType: .tiff, jpegQuality: 0.4, in: sandbox)
        #expect(highest == low)
    }

    @Test func pngOutputIsUnaffectedByJPEGQuality() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let image = try makeNoiseImage()

        let highest = try await encodedData(image, contentType: .png, jpegQuality: 1.0, in: sandbox)
        let low = try await encodedData(image, contentType: .png, jpegQuality: 0.4, in: sandbox)
        #expect(highest == low)
    }

    // MARK: - トリミング（EditInfo.cropRect）の適用

    /// 左半分 `left`・右半分 `right` の一様色で塗った CGImage。
    private func makeSplitColorImage(width: Int, height: Int, left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8)) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let color = x < width / 2 ? left : right
                pixels[index] = color.0
                pixels[index + 1] = color.1
                pixels[index + 2] = color.2
                pixels[index + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func meanChannels(of image: CGImage) throws -> (r: Double, g: Double, b: Double) {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var r = 0.0, g = 0.0, b = 0.0
        let count = width * height
        for index in stride(from: 0, to: buffer.count, by: 4) {
            r += Double(buffer[index])
            g += Double(buffer[index + 1])
            b += Double(buffer[index + 2])
        }
        return (r / Double(count), g / Double(count), b / Double(count))
    }

    @Test func croppedToDisplayRectWithoutRotationTakesTopLeft() throws {
        let image = try makeSplitColorImage(width: 200, height: 100, left: (255, 0, 0), right: (0, 0, 255))
        // 左半分（表示 = 原本、回転なし）。
        let result = UpscaleExporter.cropped(image, toDisplayRect: CGRect(x: 0, y: 0, width: 0.5, height: 1), rotation: 0)
        #expect(result.width == 100)
        #expect(result.height == 100)
        let mean = try meanChannels(of: result)
        #expect(mean.r > 240 && mean.b < 15)
    }

    @Test func croppedToDisplayRectNilAndFullRectReturnSameImage() throws {
        let image = try makeSplitColorImage(width: 120, height: 80, left: (10, 20, 30), right: (40, 50, 60))
        #expect(UpscaleExporter.cropped(image, toDisplayRect: nil, rotation: 90).width == 120)
        let full = UpscaleExporter.cropped(image, toDisplayRect: CGRect(x: 0, y: 0, width: 1, height: 1), rotation: 270)
        #expect(full.width == 120 && full.height == 80)
    }

    /// 回転 90 度時、cropRect は「回転後に表示されている画像」基準で解釈される。
    /// 200x100 を 90 度回転 → 表示 100x200。表示の上半分は原本の左半分にあたる。
    @Test func croppedToDisplayRectAccountsForNinetyDegreeRotation() throws {
        let image = try makeSplitColorImage(width: 200, height: 100, left: (255, 0, 0), right: (0, 0, 255))

        let topHalf = UpscaleExporter.cropped(image, toDisplayRect: CGRect(x: 0, y: 0, width: 1, height: 0.5), rotation: 90)
        // 原本の左半分（100x100）を切り抜く。
        #expect(topHalf.width == 100 && topHalf.height == 100)
        let topMean = try meanChannels(of: topHalf)
        #expect(topMean.r > 240 && topMean.b < 15)

        let bottomHalf = UpscaleExporter.cropped(image, toDisplayRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), rotation: 90)
        let bottomMean = try meanChannels(of: bottomHalf)
        #expect(bottomMean.b > 240 && bottomMean.r < 15)
    }

    @Test func croppedToDisplayRectHandlesOneEightyAndTwoSeventy() throws {
        let image = try makeSplitColorImage(width: 200, height: 100, left: (255, 0, 0), right: (0, 0, 255))

        // 180 度: 表示の右半分は原本の左半分（赤）。
        let rot180Right = UpscaleExporter.cropped(image, toDisplayRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), rotation: 180)
        #expect(rot180Right.width == 100 && rot180Right.height == 100)
        #expect(try meanChannels(of: rot180Right).r > 240)

        // 270 度: 表示 100x200 の下半分は原本の左半分（赤）。
        let rot270Bottom = UpscaleExporter.cropped(image, toDisplayRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), rotation: 270)
        #expect(rot270Bottom.width == 100 && rot270Bottom.height == 100)
        #expect(try meanChannels(of: rot270Bottom).r > 240)
    }

    /// end-to-end: トリミング + 回転 + 2x 拡大の書き出し。現像チェーン経由と同じ構図・寸法になる。
    @Test func exportAppliesCropBeforeUpscale() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sourceImage = try makeSplitColorImage(width: 200, height: 100, left: (255, 0, 0), right: (0, 0, 255))
        let source = sandbox.appendingPathComponent("split.png")
        let sourceDestination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(sourceDestination, sourceImage, nil)
        #expect(CGImageDestinationFinalize(sourceDestination))

        let outDir = sandbox.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let destination = outDir.appendingPathComponent("split_upscaled.png")

        let descriptor = SuperResolutionModelCatalog.lanczos(scaleFactor: 2)
        let exporter = UpscaleExporter(
            engine: SuperResolutionModelCatalog.makeEngine(for: descriptor), descriptor: descriptor
        )
        let stream = AsyncStream<Double>.makeStream(of: Double.self)
        try await exporter.export(
            source: source, destination: destination,
            rotation: 90, cropRect: CGRect(x: 0, y: 0, width: 1, height: 0.5),
            currentFolder: nil, folderPhotoURLs: [],
            jpegQuality: 1.0, progress: stream.continuation
        )
        stream.continuation.finish()

        // 原本左半分 100x100 → 90 度回転で 100x100 → 2x で 200x200、ほぼ全面赤。
        let outSource = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let output = try #require(CGImageSourceCreateImageAtIndex(outSource, 0, nil))
        #expect(output.width == 200)
        #expect(output.height == 200)
        let mean = try meanChannels(of: output)
        #expect(mean.r > 230 && mean.b < 25)
    }

    // MARK: - プロパティ組み立て

    @Test func lossyCompressionQualityIsOmittedWhenNil() {
        let withQuality = UpscaleExporter.imageProperties(
            modelID: "test", isTrainedAlgorithmicMedia: false, jpegQuality: 0.65
        )
        #expect(withQuality[kCGImageDestinationLossyCompressionQuality] as? Double == 0.65)

        let withoutQuality = UpscaleExporter.imageProperties(
            modelID: "test", isTrainedAlgorithmicMedia: false, jpegQuality: nil
        )
        #expect(withoutQuality[kCGImageDestinationLossyCompressionQuality] == nil)
    }
}
