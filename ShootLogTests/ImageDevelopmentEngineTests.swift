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

    /// テストごとに隔離した現像ベースキャッシュを持つエンジン。
    /// 実ユーザーの develop-base-v1 へ書き込ませない。
    private func makeEngine(in sandbox: URL) -> ImageDevelopmentEngine {
        ImageDevelopmentEngine(
            baseCacheDirectory: sandbox.appendingPathComponent("engine-base-cache", isDirectory: true),
            baseCacheMaxBytes: .max
        )
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
        try writePNG(image, to: url)
        return url
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @discardableResult
    private func writeJPEG(width: Int, height: Int, in sandbox: URL) throws -> URL {
        let image = try makeColorImage(width: width, height: height)
        let url = sandbox.appendingPathComponent("\(UUID().uuidString).jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// 全ピクセルが同じグレー値の画像。
    private func makeSolidImage(gray: UInt8, size: Int) throws -> CGImage {
        let pixels = [UInt8](repeating: gray, count: size * size * 4).enumerated().map { index, value in
            index % 4 == 3 ? 255 : value
        }
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
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

    @Test func rawExtensionsAreDetectedCaseInsensitively() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let engine = makeEngine(in: sandbox)
        let base = URL(fileURLWithPath: "/tmp/sample")

        for ext in ["NEF", "dng", "Arw", "cr3", "RAF"] {
            #expect(engine.isRAW(url: base.appendingPathExtension(ext)))
        }
        for ext in ["jpg", "JPEG", "png", "heic", "tiff"] {
            #expect(engine.isRAW(url: base.appendingPathExtension(ext)) == false)
        }
    }

    // MARK: - 撮影時ホワイトバランス

    @Test func asShotNeutralForNonRAWReturnsEstimatedSample() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = makeEngine(in: sandbox)

        let sample = try #require(await engine.asShotNeutral(for: url))
        #expect(sample.isEstimated)
        #expect(sample.temperatureKelvin.isFinite)
        #expect((1_000...50_000).contains(sample.temperatureKelvin))
    }

    @Test func asShotNeutralForJPEGReturnsEstimatedSample() async throws {
        let sandbox = try makeSandbox()
        let url = try writeJPEG(width: 128, height: 96, in: sandbox)
        let engine = makeEngine(in: sandbox)

        let sample = try #require(await engine.asShotNeutral(for: url))
        #expect(sample.isEstimated)
    }

    @Test func asShotNeutralCachesBySourceModificationTime() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = makeEngine(in: sandbox)

        let first = try #require(await engine.asShotNeutral(for: url))
        let second = try #require(await engine.asShotNeutral(for: url))
        #expect(first == second)
        #expect(await engine.asShotCacheCountForTesting() == 1)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: url.path
        )
        _ = try #require(await engine.asShotNeutral(for: url))
        #expect(await engine.asShotCacheCountForTesting() == 2)
    }

    @Test func rawParameterBaseCacheDoesNotUseDiskLayer() {
        #expect(ImageDevelopmentEngine.shouldUseDiskBaseCache(bucket: 1, rawParameters: nil))
        #expect(ImageDevelopmentEngine.shouldUseDiskBaseCache(bucket: 1, rawParameters: .neutral) == false)
        #expect(ImageDevelopmentEngine.shouldUseDiskBaseCache(bucket: 0, rawParameters: nil) == false)
    }

    @Test func rawPreviewDecodeTargetIsCappedAtProxyLongEdge() {
        let capped = ImageDevelopmentEngine.previewDecodeTarget(
            8_000,
            cropRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            hasRAWParameters: true
        )
        #expect(capped == CGFloat(PreviewCacheStore.shared.proxyLongEdge))
        #expect(ImageDevelopmentEngine.previewDecodeTarget(
            8_000, cropRect: nil, hasRAWParameters: false
        ) == 8_000)
    }

    @Test func asShotNeutralForMissingFileReturnsNil() async throws {
        let sandbox = try makeSandbox()
        let missing = sandbox.appendingPathComponent("does-not-exist.png")
        let engine = makeEngine(in: sandbox)

        #expect(await engine.asShotNeutral(for: missing) == nil)
    }

    /// RAW 経路は実 RAW フィクスチャ不足のため手動検証する。
    @Test func asShotNeutralForMissingRAWReturnsNil() async throws {
        let sandbox = try makeSandbox()
        let missing = sandbox.appendingPathComponent("does-not-exist.dng")
        let engine = makeEngine(in: sandbox)

        #expect(await engine.asShotNeutral(for: missing) == nil)
    }

    // MARK: - プレビュー

    @Test func neutralPreviewKeepsSourceDimensionsWhenSmallerThanTarget() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = makeEngine(in: sandbox)

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
        let engine = makeEngine(in: sandbox)

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
        let engine = makeEngine(in: sandbox)

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
        let engine = makeEngine(in: sandbox)

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
        let engine = makeEngine(in: sandbox)

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

    @Test func previewBakesRotationAndCrop() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 400, height: 200, in: sandbox)
        let engine = makeEngine(in: sandbox)

        // 90度回転 → 見かけ 200x400。左半分(x:0, w:0.5)を切り抜き。
        let preview = try #require(
            await engine.renderPreview(
                url: url, parameters: .neutral, targetMaxPixelSize: 512,
                rotation: 90, cropRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)
            )
        )
        // 回転後 200x400 の左半分 → アスペクト比 1:4
        let aspect = Double(preview.width) / Double(preview.height)
        #expect(abs(aspect - 0.25) < 0.05)
    }

    @Test func previewCropUpscalesBaseDecodeForResolution() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 2000, height: 2000, in: sandbox)
        let engine = makeEngine(in: sandbox)

        // 20% クロップ。ベースデコードが target まで引き上げられ、切り抜き後も解像度が保たれる。
        let crop = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let preview = try #require(
            await engine.renderPreview(
                url: url, parameters: .neutral, targetMaxPixelSize: 512,
                rotation: 0, cropRect: crop
            )
        )
        // クロップ前提を無視すると長辺 ≒ 512 * 0.2 ≒ 102px まで落ちる。
        // decodeTarget が効いていれば 200px 以上を保てる（上限 4 倍なので厳密一致は求めない）。
        #expect(max(preview.width, preview.height) >= 200)
    }

    // MARK: - フル解像度

    @Test func renderFullKeepsSourceDimensions() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = makeEngine(in: sandbox)

        let full = try #require(await engine.renderFull(url: url, parameters: .neutral, rotation: 0, cropRect: nil))
        #expect(full.width == 128)
        #expect(full.height == 96)
    }

    @Test func renderFullAppliesAdjustments() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = makeEngine(in: sandbox)

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1.0

        let neutral = try #require(await engine.renderFull(url: url, parameters: .neutral, rotation: 0, cropRect: nil))
        let brightened = try #require(await engine.renderFull(url: url, parameters: parameters, rotation: 0, cropRect: nil))
        #expect(try meanLuma(of: brightened) > meanLuma(of: neutral))
    }

    /// プレビュー（縮小）と書き出し（フル解像度）が同じ調整結果になること（WYSIWYG）。
    /// 2 つの解像度でレンダーし、共通サイズへ縮小して平均色を比較する。
    @Test func adjustmentIsSizeInvariant() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 400, height: 300, in: sandbox)
        let engine = makeEngine(in: sandbox)

        var parameters = DevelopParameters.neutral
        parameters.exposure = 0.8
        parameters.contrast = 40
        parameters.saturation = -30

        let small = try #require(
            await engine.renderPreview(url: url, parameters: parameters, targetMaxPixelSize: 128)
        )
        let large = try #require(
            await engine.renderFull(url: url, parameters: parameters, rotation: 0, cropRect: nil)
        )

        #expect(abs(try meanLuma(of: small) - meanLuma(of: large)) < 6)
    }

    @Test func renderFullQuarterRotationSwapsDimensions() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 120, height: 80, in: sandbox)
        let engine = makeEngine(in: sandbox)

        let rotated = try #require(
            await engine.renderFull(url: url, parameters: .neutral, rotation: 90, cropRect: nil)
        )
        #expect(rotated.width == 80)
        #expect(rotated.height == 120)
    }

    @Test func renderFullCropReducesDimensions() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 200, height: 100, in: sandbox)
        let engine = makeEngine(in: sandbox)

        let crop = CGRect(x: 0.25, y: 0.0, width: 0.5, height: 1.0)
        let cropped = try #require(
            await engine.renderFull(url: url, parameters: .neutral, rotation: 0, cropRect: crop)
        )
        #expect(cropped.width == 100)
        #expect(cropped.height == 100)
    }

    /// トリミング矩形は「回転適用後の画像」を基準に解釈される。
    /// 回転のみ適用した結果の左上 1/4 と、回転 + 同じ矩形でトリミングした結果が一致することで、
    /// crop が回転後・左上原点の座標系で効いていることを確認する（座標系の回帰ガード）。
    @Test func renderFullCropIsRelativeToRotatedImage() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 200, height: 100, in: sandbox)
        let engine = makeEngine(in: sandbox)

        let rotatedFull = try #require(
            await engine.renderFull(url: url, parameters: .neutral, rotation: 90, cropRect: nil)
        )
        let halfWidth = rotatedFull.width / 2
        let halfHeight = rotatedFull.height / 2

        let crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let cropped = try #require(
            await engine.renderFull(url: url, parameters: .neutral, rotation: 90, cropRect: crop)
        )
        #expect(cropped.width == halfWidth)
        #expect(cropped.height == halfHeight)

        // CGImage は左上原点。回転結果の左上 1/4 を取り出して平均色を比較する。
        let expectedRegion = try #require(rotatedFull.cropping(to: CGRect(
            x: 0, y: 0, width: CGFloat(halfWidth), height: CGFloat(halfHeight)
        )))
        let expected = try meanChannels(of: expectedRegion)
        let actual = try meanChannels(of: cropped)
        #expect(abs(actual.red - expected.red) < 5)
        #expect(abs(actual.green - expected.green) < 5)
        #expect(abs(actual.blue - expected.blue) < 5)
    }

    // MARK: - Stage A キャッシュ

    /// 同じパスのファイルが差し替えられたら、Stage A キャッシュの古いデコード結果を返さない。
    @Test func baseCacheInvalidatesWhenSourceFileChanges() async throws {
        let sandbox = try makeSandbox()
        let url = sandbox.appendingPathComponent("subject.png")
        let engine = makeEngine(in: sandbox)

        try writePNG(try makeSolidImage(gray: 40, size: 64), to: url)
        let dark = try #require(
            await engine.renderPreview(url: url, parameters: .neutral, targetMaxPixelSize: 256)
        )
        let darkLuma = try meanLuma(of: dark)

        // 明るい画像で上書きし、mtime を確実に進める（sleep に頼らず属性で固定）。
        try writePNG(try makeSolidImage(gray: 220, size: 64), to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: url.path
        )
        let light = try #require(
            await engine.renderPreview(url: url, parameters: .neutral, targetMaxPixelSize: 256)
        )

        #expect(try meanLuma(of: light) > darkLuma + 80)
    }

    @Test func neutralBaseCachePersistsLosslesslyAcrossEngineInstances() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = try writePNG(width: 640, height: 400, in: sandbox)
        let cacheDirectory = sandbox.appendingPathComponent("develop-base", isDirectory: true)
        let firstEngine = ImageDevelopmentEngine(baseCacheDirectory: cacheDirectory, baseCacheMaxBytes: .max)

        let first = try #require(
            await firstEngine.renderPreview(url: source, parameters: .neutral, targetMaxPixelSize: 256)
        )
        await firstEngine.waitForBaseCacheWritesForTesting()
        #expect(try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension == "png" })

        let reloadedEngine = ImageDevelopmentEngine(baseCacheDirectory: cacheDirectory, baseCacheMaxBytes: .max)
        let reloaded = try #require(
            await reloadedEngine.renderPreview(url: source, parameters: .neutral, targetMaxPixelSize: 256)
        )
        #expect(try rgbaBytes(of: reloaded) == rgbaBytes(of: first))
    }

    @Test func developBaseCacheEvictsOldestDiskEntry() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let firstSource = try writePNG(width: 640, height: 400, in: sandbox)
        let secondSource = try writePNG(width: 641, height: 400, in: sandbox)
        let cacheDirectory = sandbox.appendingPathComponent("develop-base", isDirectory: true)
        let writer = ImageDevelopmentEngine(baseCacheDirectory: cacheDirectory, baseCacheMaxBytes: .max)

        _ = try #require(await writer.renderPreview(
            url: firstSource, parameters: .neutral, targetMaxPixelSize: 256
        ))
        await writer.waitForBaseCacheWritesForTesting()
        let firstFile = try #require(
            try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 1)], ofItemAtPath: firstFile.path
        )

        _ = try #require(await writer.renderPreview(
            url: secondSource, parameters: .neutral, targetMaxPixelSize: 256
        ))
        await writer.waitForBaseCacheWritesForTesting()
        let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        let secondFile = try #require(files.first { $0 != firstFile })
        let maxBytes = max(
            try #require(firstFile.resourceValues(forKeys: [.fileSizeKey]).fileSize),
            try #require(secondFile.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 2)], ofItemAtPath: secondFile.path
        )

        let limiter = ImageDevelopmentEngine(baseCacheDirectory: cacheDirectory, baseCacheMaxBytes: maxBytes)
        await limiter.warmUpCaches()
        let remaining = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        #expect(remaining == [secondFile])
    }

    // MARK: - 出力カラースペース

    @Test func renderFullDefaultsToSRGBOutput() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 64, height: 48, in: sandbox)
        let engine = makeEngine(in: sandbox)

        let output = try #require(
            await engine.renderFull(url: url, parameters: .neutral, rotation: 0, cropRect: nil)
        )
        let name = output.colorSpace?.name as String?
        #expect(name == (CGColorSpace.sRGB as String))
    }

    @Test func renderFullHonorsRequestedOutputColorSpace() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 64, height: 48, in: sandbox)
        let engine = makeEngine(in: sandbox)
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))

        let output = try #require(
            await engine.renderFull(
                url: url, parameters: .neutral, rotation: 0, cropRect: nil, outputColorSpace: p3
            )
        )
        #expect((output.colorSpace?.name as String?) == (CGColorSpace.displayP3 as String))
    }

    @Test func renderPreviewDefaultsToSRGB() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = makeEngine(in: sandbox)

        var params = DevelopParameters.neutral
        params.exposure = 0.5
        let preview = try #require(
            await engine.renderPreview(url: url, parameters: params, targetMaxPixelSize: 256)
        )
        #expect((preview.colorSpace?.name as String?) == (CGColorSpace.sRGB as String))
    }

    @Test func renderPreviewHonorsRequestedDisplayColorSpace() async throws {
        let sandbox = try makeSandbox()
        let url = try writePNG(width: 128, height: 96, in: sandbox)
        let engine = makeEngine(in: sandbox)
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))

        var params = DevelopParameters.neutral
        params.saturation = 100   // 色域外へ振ってエンコード差が出るようにする

        let sRGBPreview = try #require(
            await engine.renderPreview(
                url: url, parameters: params, targetMaxPixelSize: 256,
                previewColorSpace: nil
            )
        )
        let p3Preview = try #require(
            await engine.renderPreview(
                url: url, parameters: params, targetMaxPixelSize: 256,
                previewColorSpace: p3
            )
        )

        #expect((sRGBPreview.colorSpace?.name as String?) == (CGColorSpace.sRGB as String))
        #expect((p3Preview.colorSpace?.name as String?) == (CGColorSpace.displayP3 as String))

        // 同じ色でも P3 と sRGB では原色が違うため、ネイティブ空間でのエンコード値が変わる。
        let sRGBFallback = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func nativeMean(of image: CGImage) -> (r: Double, g: Double, b: Double) {
            let width = image.width
            let height = image.height
            let space = image.colorSpace ?? sRGBFallback
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            _ = buffer.withUnsafeMutableBytes { raw in
                CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var totals = (0.0, 0.0, 0.0)
            let count = Double(width * height)
            for index in stride(from: 0, to: buffer.count, by: 4) {
                totals.0 += Double(buffer[index])
                totals.1 += Double(buffer[index + 1])
                totals.2 += Double(buffer[index + 2])
            }
            return (totals.0 / count, totals.1 / count, totals.2 / count)
        }

        let sRGBMean = nativeMean(of: sRGBPreview)
        let p3Mean = nativeMean(of: p3Preview)
        let delta = abs(sRGBMean.r - p3Mean.r) + abs(sRGBMean.g - p3Mean.g) + abs(sRGBMean.b - p3Mean.b)
        #expect(delta > 3)
    }

    // MARK: - 失敗系

    @Test func missingFileReturnsNilInsteadOfCrashing() async throws {
        let sandbox = try makeSandbox()
        let missing = sandbox.appendingPathComponent("does-not-exist.png")
        let engine = makeEngine(in: sandbox)

        #expect(await engine.renderPreview(
            url: missing, parameters: .neutral, targetMaxPixelSize: 256
        ) == nil)
        #expect(await engine.renderFull(url: missing, parameters: .neutral, rotation: 0, cropRect: nil) == nil)
    }
}
