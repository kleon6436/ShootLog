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
