import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import ShootLog

struct DevelopPipelineTests {

    private static let side = 32

    // MARK: - ヘルパー

    /// テスト用の CIContext。作業・出力とも sRGB に固定してエンジン側と条件を揃える。
    private func makeContext() throws -> CIContext {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
    }

    /// R と G が位置で変化し B が一定の、決定論的なカラー画像。
    /// 単色だと彩度・コントラスト・カーブの効果が測れないため階調を持たせている。
    private func makeTestImage() throws -> CIImage {
        let side = Self.side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                pixels[index] = UInt8(8 + x * 6)        // R: 8...194
                pixels[index + 1] = UInt8(40 + y * 4)   // G: 40...164
                pixels[index + 2] = 120                 // B: 一定
                pixels[index + 3] = 255
            }
        }

        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        return CIImage(cgImage: cgImage)
    }

    /// 画像を sRGB の RGBA8 ビットマップへ展開する。
    private func renderRGBA(_ image: CIImage, context: CIContext) throws -> [UInt8] {
        let rect = image.extent.integral
        let width = Int(rect.width)
        let height = Int(rect.height)
        #expect(width > 0 && height > 0)

        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                image,
                toBitmap: base,
                rowBytes: width * 4,
                bounds: rect,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        return buffer
    }

    // MARK: - RAW 露出・WB の委譲

    @Test func skipExposureAndWhiteBalanceOmitsThoseFilters() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var params = DevelopParameters.neutral
        params.exposure = 1.0
        params.temperature = 40

        let standard = DevelopPipeline.apply(params, to: input, isRAW: true)
        let skipped = DevelopPipeline.apply(params, to: input, isRAW: true, skipExposureAndWhiteBalance: true)

        let inputMean = mean(try renderRGBA(input, context: context))
        let standardMean = mean(try renderRGBA(standard, context: context))
        let skippedMean = mean(try renderRGBA(skipped, context: context))

        // 標準チェーンは露出で明るくなる。skip 版は入力とほぼ同じ（CIRAWFilter 側で処理される想定）。
        #expect(standardMean > inputMean + 10)
        #expect(abs(skippedMean - inputMean) < 3)
    }

    @Test func skipExposureAndWhiteBalanceStillAppliesOtherAdjustments() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var params = DevelopParameters.neutral
        params.exposure = 1.0        // 委譲対象（skip される）
        params.saturation = -100     // 非委譲（適用される）

        let skipped = DevelopPipeline.apply(params, to: input, isRAW: true, skipExposureAndWhiteBalance: true)
        let pixels = try renderRGBA(skipped, context: context)

        // 彩度 -100 で R/G/B がほぼ等しくなる（グレースケール化）。
        let redRange = range(pixels, channel: 0)
        let greenRange = range(pixels, channel: 1)
        #expect(abs(redRange.max - greenRange.max) < 20)
    }

    private func mean(_ pixels: [UInt8]) -> Double {
        var total = 0.0
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])
            count += 3
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// 指定チャンネル（0=R, 1=G, 2=B）の最小値と最大値。
    private func range(_ pixels: [UInt8], channel: Int) -> (min: Int, max: Int) {
        var minimum = 255
        var maximum = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = Int(pixels[index + channel])
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        return (minimum, maximum)
    }

    private func maxAbsoluteDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        guard lhs.count == rhs.count else { return .max }
        var worst = 0
        for index in lhs.indices {
            worst = max(worst, abs(Int(lhs[index]) - Int(rhs[index])))
        }
        return worst
    }

    // MARK: - 恒等性

    @Test func neutralParametersProduceIdenticalPixels() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        let output = DevelopPipeline.apply(.neutral, to: input, isRAW: false)

        #expect(output.extent == input.extent)
        let before = try renderRGBA(input, context: context)
        let after = try renderRGBA(output, context: context)
        #expect(maxAbsoluteDifference(before, after) <= 2)
    }

    @Test func hasAnyEffectTracksNeutrality() {
        #expect(DevelopPipeline.hasAnyEffect(.neutral) == false)

        var parameters = DevelopParameters.neutral
        parameters.exposure = 0.5
        #expect(DevelopPipeline.hasAnyEffect(parameters))
    }

    // MARK: - 基本調整

    @Test func positiveExposureBrightensImage() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1.0

        let baseline = try renderRGBA(input, context: context)
        let brightened = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false),
            context: context
        )
        #expect(mean(brightened) > mean(baseline))
    }

    @Test func fullNegativeSaturationProducesGrayscale() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var parameters = DevelopParameters.neutral
        parameters.saturation = -100

        let pixels = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false),
            context: context
        )
        var worstSpread = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            worstSpread = max(worstSpread, max(red, green, blue) - min(red, green, blue))
        }
        #expect(worstSpread <= 4)
    }

    @Test func positiveContrastExpandsTonalRange() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var parameters = DevelopParameters.neutral
        parameters.contrast = 100

        let baseline = range(try renderRGBA(input, context: context), channel: 0)
        let boosted = range(
            try renderRGBA(DevelopPipeline.apply(parameters, to: input, isRAW: false), context: context),
            channel: 0
        )
        #expect(boosted.max - boosted.min > baseline.max - baseline.min)
    }

    // MARK: - トーンカーブ

    @Test func invertedToneCurveInvertsOutput() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var parameters = DevelopParameters.neutral
        parameters.toneCurveRGB = [CurvePoint(x: 0, y: 1), CurvePoint(x: 1, y: 0)]

        let before = try renderRGBA(input, context: context)
        let after = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false),
            context: context
        )

        var worst = 0
        for index in stride(from: 0, to: before.count, by: 4) {
            for channel in 0..<3 {
                let expected = 255 - Int(before[index + channel])
                worst = max(worst, abs(Int(after[index + channel]) - expected))
            }
        }
        #expect(worst <= 12)
    }

    @Test func perChannelCurveOnlyMovesThatChannel() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var parameters = DevelopParameters.neutral
        parameters.toneCurveRed = [CurvePoint(x: 0, y: 1), CurvePoint(x: 1, y: 0)]

        let before = try renderRGBA(input, context: context)
        let after = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false),
            context: context
        )

        var worstRed = 0
        var worstOther = 0
        for index in stride(from: 0, to: before.count, by: 4) {
            worstRed = max(worstRed, abs(Int(after[index]) - Int(before[index])))
            worstOther = max(worstOther, abs(Int(after[index + 1]) - Int(before[index + 1])))
            worstOther = max(worstOther, abs(Int(after[index + 2]) - Int(before[index + 2])))
        }
        #expect(worstRed > 20)
        #expect(worstOther <= 4)
    }

    // MARK: - HSL

    @Test func singleBandSaturationChangesOutput() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var parameters = DevelopParameters.neutral
        var bands = parameters.hslSaturation
        bands[0] = 100   // red 帯域
        parameters.hslSaturation = bands

        let before = try renderRGBA(input, context: context)
        let after = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false),
            context: context
        )
        #expect(maxAbsoluteDifference(before, after) > 2)
    }

    @Test func hslCacheProducesSameResultAsUncached() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var parameters = DevelopParameters.neutral
        parameters.hslSaturation[3] = 70   // green 帯域
        parameters.exposure = 0.4

        let uncached = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false),
            context: context
        )
        let cache = DevelopPipelineCache()
        // 2 回通して 2 回目がキャッシュヒット経路になることも確認する
        _ = DevelopPipeline.apply(parameters, to: input, isRAW: false, cache: cache)
        let cached = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false, cache: cache),
            context: context
        )
        #expect(maxAbsoluteDifference(uncached, cached) <= 1)
    }

    // MARK: - 極端値

    @Test(arguments: [1.0, -1.0])
    func extremeParametersStayRenderable(_ sign: Double) throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var parameters = DevelopParameters.neutral
        parameters.exposure = 3 * sign
        parameters.contrast = 100 * sign
        parameters.highlights = 100 * sign
        parameters.shadows = 100 * sign
        parameters.whites = 100 * sign
        parameters.blacks = 100 * sign
        parameters.brightness = 100 * sign
        parameters.temperature = 100 * sign
        parameters.tint = 100 * sign
        parameters.vibrance = 100 * sign
        parameters.saturation = 100 * sign
        parameters.sharpness = 100 * sign
        parameters.luminanceNoiseReduction = 100
        parameters.colorNoiseReduction = 100
        parameters.hslHue = Array(repeating: 100 * sign, count: HSLBand.allCases.count)
        parameters.hslSaturation = Array(repeating: 100 * sign, count: HSLBand.allCases.count)
        parameters.hslLuminance = Array(repeating: 100 * sign, count: HSLBand.allCases.count)

        let output = DevelopPipeline.apply(parameters, to: input, isRAW: true)
        #expect(output.extent == input.extent)

        let pixels = try renderRGBA(output, context: context)
        #expect(pixels.count == Self.side * Self.side * 4)
    }
}
