import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

struct DevelopExporterTests {

    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DevelopExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 決定論的なカラー PNG を書き出す。
    @discardableResult
    private func writePNG(width: Int, height: Int, to url: URL) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 0x1234_5678
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 16)
            pixels[index + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            pixels[index + 2] = UInt8(truncatingIfNeeded: seed)
            pixels[index + 3] = 255
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func dimensions(of url: URL) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(props[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(props[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }

    // MARK: - 基本の書き出し

    @Test func exportsJPEGWithSourceDimensions() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sourceDir = sandbox.appendingPathComponent("src", isDirectory: true)
        let outDir = sandbox.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let source = try writePNG(width: 160, height: 120, to: sourceDir.appendingPathComponent("a.png"))
        let destination = outDir.appendingPathComponent("a_edited.jpg")

        try await DevelopExporter().export(
            source: source, destination: destination, parameters: .neutral,
            rotation: 0, cropRect: nil, contentType: .jpeg, jpegQuality: 0.9,
            currentFolder: sourceDir, folderPhotoURLs: [source]
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let (width, height) = try dimensions(of: destination)
        #expect(width == 160)
        #expect(height == 120)
    }

    @Test func exportBakesRotationAndCrop() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 200, height: 100, to: sandbox.appendingPathComponent("b.png"))
        let outDir = sandbox.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let destination = outDir.appendingPathComponent("b_edited.tiff")

        try await DevelopExporter().export(
            source: source, destination: destination, parameters: .neutral,
            rotation: 90, cropRect: CGRect(x: 0, y: 0, width: 0.5, height: 1),
            contentType: .tiff, jpegQuality: 1.0,
            currentFolder: nil, folderPhotoURLs: []
        )

        // cropRect は「回転適用後に表示されている画像」基準。
        // 200x100 を 90度回転 → 100x200 → 左半分(x:0, w:0.5)を切り抜き → 50x200
        let (width, height) = try dimensions(of: destination)
        #expect(width == 50)
        #expect(height == 200)
    }

    // MARK: - 原本保護

    @Test func rejectsDestinationInsideSourceFolder() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 64, height: 64, to: sandbox.appendingPathComponent("c.png"))
        let before = try sha256(of: source)
        let destination = sandbox.appendingPathComponent("c_edited.jpg")

        await #expect(throws: ShootLogError.self) {
            try await DevelopExporter().export(
                source: source, destination: destination, parameters: .neutral,
                rotation: 0, cropRect: nil, contentType: .jpeg, jpegQuality: 0.9,
                currentFolder: sandbox, folderPhotoURLs: [source]
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try sha256(of: source) == before)
    }

    @Test func rejectsOverwritingFolderPhoto() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 64, height: 64, to: sandbox.appendingPathComponent("d.png"))
        let other = try writePNG(width: 64, height: 64, to: sandbox.appendingPathComponent("e.png"))
        let before = try sha256(of: other)

        await #expect(throws: ShootLogError.self) {
            try await DevelopExporter().export(
                source: source, destination: other, parameters: .neutral,
                rotation: 0, cropRect: nil, contentType: .jpeg, jpegQuality: 0.9,
                currentFolder: nil, folderPhotoURLs: [source, other]
            )
        }
        #expect(try sha256(of: other) == before)
    }

    @Test func sourceBytesUnchangedAfterExport() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 96, height: 96, to: sandbox.appendingPathComponent("f.png"))
        let before = try sha256(of: source)
        let outDir = sandbox.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var parameters = DevelopParameters.neutral
        parameters.exposure = 0.5
        try await DevelopExporter().export(
            source: source, destination: outDir.appendingPathComponent("f_edited.jpg"),
            parameters: parameters, rotation: 0, cropRect: nil,
            contentType: .jpeg, jpegQuality: 0.8, currentFolder: nil, folderPhotoURLs: [source]
        )

        #expect(try sha256(of: source) == before)
    }

    // MARK: - 現像 → 超解像チェーン

    private func lanczosRequest(
        scale: Int,
        trainedAlgorithmicMedia: Bool = false
    ) -> DevelopExporter.SuperResolutionRequest {
        DevelopExporter.SuperResolutionRequest(
            engine: LanczosSuperResolutionEngine(scaleFactor: scale),
            descriptor: SuperResolutionModelDescriptor(
                id: trainedAlgorithmicMedia ? "test-ai" : SuperResolutionModelCatalog.lanczosID,
                scaleFactor: scale,
                tileLayout: .scaled(by: scale),
                isTrainedAlgorithmicMedia: trainedAlgorithmicMedia
            )
        )
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test func superResolutionChainScalesOutputAndProtectsSource() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 40, height: 30, to: sandbox.appendingPathComponent("a.png"))
        let before = try sha256(of: source)
        let destination = sandbox.appendingPathComponent("a_edited.tiff")

        try await DevelopExporter().export(
            source: source, destination: destination, parameters: .neutral,
            rotation: 0, cropRect: nil, contentType: .tiff, jpegQuality: 1.0,
            superResolution: lanczosRequest(scale: 2),
            currentFolder: nil, folderPhotoURLs: []
        )

        let (width, height) = try dimensions(of: destination)
        #expect(width == 80)
        #expect(height == 60)
        #expect(try sha256(of: source) == before)
    }

    @Test func superResolutionChainDoesNotDoubleApplyRotation() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 40, height: 30, to: sandbox.appendingPathComponent("b.png"))
        let destination = sandbox.appendingPathComponent("b_edited.tiff")

        // 40x30 を 90 度回転 → 30x40 → 2 倍 → 60x80
        try await DevelopExporter().export(
            source: source, destination: destination, parameters: .neutral,
            rotation: 90, cropRect: nil, contentType: .tiff, jpegQuality: 1.0,
            superResolution: lanczosRequest(scale: 2),
            currentFolder: nil, folderPhotoURLs: []
        )

        let (width, height) = try dimensions(of: destination)
        #expect(width == 60)
        #expect(height == 80)
    }

    @Test func superResolutionOutputCarriesModelSoftwareTag() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 32, height: 32, to: sandbox.appendingPathComponent("c.png"))
        let destination = sandbox.appendingPathComponent("c_edited.tiff")

        try await DevelopExporter().export(
            source: source, destination: destination, parameters: .neutral,
            rotation: 0, cropRect: nil, contentType: .tiff, jpegQuality: 1.0,
            superResolution: lanczosRequest(scale: 2),
            currentFolder: nil, folderPhotoURLs: []
        )

        let tiff = try #require(try properties(of: destination)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        let software = try #require(tiff[kCGImagePropertyTIFFSoftware] as? String)
        #expect(software.contains("ShootLog"))
        #expect(software.contains(SuperResolutionModelCatalog.lanczosID))
    }

    @Test func trainedAlgorithmicMediaDescriptorMarksDigitalSource() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 32, height: 32, to: sandbox.appendingPathComponent("d.png"))
        let destination = sandbox.appendingPathComponent("d_edited.tiff")

        try await DevelopExporter().export(
            source: source, destination: destination, parameters: .neutral,
            rotation: 0, cropRect: nil, contentType: .tiff, jpegQuality: 1.0,
            superResolution: lanczosRequest(scale: 2, trainedAlgorithmicMedia: true),
            currentFolder: nil, folderPhotoURLs: []
        )

        let iptc = try #require(try properties(of: destination)[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        let sourceType = iptc[kCGImagePropertyIPTCExtDigitalSourceType] as? String
        #expect(sourceType == UpscaleExporter.trainedAlgorithmicMediaURI)
    }

    @Test func noSuperResolutionOmitsDigitalSourceType() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 32, height: 32, to: sandbox.appendingPathComponent("e.png"))
        let destination = sandbox.appendingPathComponent("e_edited.tiff")

        try await DevelopExporter().export(
            source: source, destination: destination, parameters: .neutral,
            rotation: 0, cropRect: nil, contentType: .tiff, jpegQuality: 1.0,
            currentFolder: nil, folderPhotoURLs: []
        )

        let props = try properties(of: destination)
        #expect(props[kCGImagePropertyIPTCDictionary] == nil)
    }

    // MARK: - メタデータ

    @Test func softwareTagIsPresent() {
        let properties = DevelopExporter.imageProperties(
            sourceURL: URL(fileURLWithPath: "/tmp/none.png"), jpegQuality: 0.9
        )
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let software = tiff?[kCGImagePropertyTIFFSoftware] as? String
        #expect(software?.hasPrefix("ShootLog") == true)
    }

    @Test func lossyQualityOmittedForLosslessFormats() {
        let jpeg = DevelopExporter.imageProperties(
            sourceURL: URL(fileURLWithPath: "/tmp/none.png"), jpegQuality: 0.6
        )
        #expect(jpeg[kCGImageDestinationLossyCompressionQuality] as? Double == 0.6)

        let tiff = DevelopExporter.imageProperties(
            sourceURL: URL(fileURLWithPath: "/tmp/none.png"), jpegQuality: nil
        )
        #expect(tiff[kCGImageDestinationLossyCompressionQuality] == nil)
    }
}
