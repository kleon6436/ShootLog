import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import ShootLog

struct DevelopPipelineTests {

    private static let side = 32

    // MARK: - ヘルパー

    /// テスト用の CIContext。作業空間 linearSRGB / 出力 sRGB で `ImageDevelopmentEngine.sharedContext`
    /// と条件を揃える。知覚ブラケット（`DevelopPipeline` の sRGB 区間）が本番と同じ空間で評価される。
    private func makeContext() throws -> CIContext {
        let working = try #require(CGColorSpace(name: CGColorSpace.linearSRGB))
        let output = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return CIContext(options: [.workingColorSpace: working, .outputColorSpace: output])
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

    /// 左上三角を `low`、右下三角を `high` の一様グレーで塗った sRGB 画像。
    /// 中央 128 対称の 2 値を与えて、トーン調整の対称性・方向を測るのに使う。
    private func makeSplitImage(low: UInt8, high: UInt8) throws -> CIImage {
        let side = Self.side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                let value = (x + y) < side ? low : high
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
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

    private func meanChannel(
        _ pixels: [UInt8],
        channel: Int,
        where includes: (Int, Int) -> Bool
    ) -> Double {
        var total = 0.0
        var count = 0
        for y in 0..<Self.side {
            for x in 0..<Self.side where includes(x, y) {
                total += Double(pixels[(y * Self.side + x) * 4 + channel])
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
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

    @Test func nonRAWCustomWhiteBalanceAtAsShotBaselineIsIdentity() throws {
        let context = try makeContext()
        let input = try makeTestImage()
        var parameters = DevelopParameters.neutral
        parameters.whiteBalance = WhiteBalanceSettings(mode: .custom, temperatureKelvin: 5200, tint: 0)
        let asShot = WhiteBalanceSample(temperatureKelvin: 5_200, tint: 0, isEstimated: true)

        let before = try renderRGBA(input, context: context)
        let after = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false, asShotWhiteBalance: asShot),
            context: context
        )

        #expect(maxAbsoluteDifference(before, after) <= 3)
    }

    @Test func nonRAWCustomWhiteBalanceWarmsWhenAboveAsShot() throws {
        let context = try makeContext()
        let input = try makeTestImage()
        var parameters = DevelopParameters.neutral
        parameters.whiteBalance = WhiteBalanceSettings(mode: .custom, temperatureKelvin: 7200, tint: 0)
        let asShot = WhiteBalanceSample(temperatureKelvin: 5_200, tint: 0, isEstimated: true)

        let baseline = try renderRGBA(input, context: context)
        let warmed = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false, asShotWhiteBalance: asShot),
            context: context
        )

        #expect(meanChannel(warmed, channel: 0, where: { _, _ in true }) > meanChannel(warmed, channel: 2, where: { _, _ in true }))
        #expect(maxAbsoluteDifference(baseline, warmed) > 3)
    }

    @Test func colorGradingNeutralIsIdentity() throws {
        let context = try makeContext()
        let input = try makeTestImage()
        var parameters = DevelopParameters.neutral
        parameters.contrast = 20

        let legacy = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false), context: context
        )
        let graded = try renderRGBA(
            DevelopPipeline.apply(
                parameters,
                to: input,
                isRAW: false,
                usesToneMaskedColorGrading: true
            ),
            context: context
        )

        #expect(maxAbsoluteDifference(legacy, graded) <= 2)
    }

    // MARK: - トーン域マスク・カラーグレーディング

    @Test func shadowTintOnlyAffectsDarks() throws {
        let context = try makeContext()
        let input = try makeSplitImage(low: 30, high: 220)
        var parameters = DevelopParameters.neutral
        parameters.colorBalance.shadows = ColorBalanceComponent(hue: 240, saturation: 80)

        let baseline = try renderRGBA(input, context: context)
        let graded = try renderRGBA(
            DevelopPipeline.apply(
                parameters,
                to: input,
                isRAW: false,
                usesToneMaskedColorGrading: true
            ),
            context: context
        )
        let isShadow: (Int, Int) -> Bool = { $0 + $1 < Self.side }
        let isHighlight: (Int, Int) -> Bool = { !isShadow($0, $1) }

        #expect(meanChannel(graded, channel: 2, where: isShadow) > meanChannel(baseline, channel: 2, where: isShadow) + 4)
        for channel in 0..<3 {
            #expect(abs(meanChannel(graded, channel: channel, where: isHighlight) - meanChannel(baseline, channel: channel, where: isHighlight)) <= 3)
        }
    }

    @Test func highlightTintOnlyAffectsBrights() throws {
        let context = try makeContext()
        let input = try makeSplitImage(low: 30, high: 220)
        var parameters = DevelopParameters.neutral
        parameters.colorBalance.highlights = ColorBalanceComponent(hue: 30, saturation: 80)

        let baseline = try renderRGBA(input, context: context)
        let graded = try renderRGBA(
            DevelopPipeline.apply(
                parameters,
                to: input,
                isRAW: false,
                usesToneMaskedColorGrading: true
            ),
            context: context
        )
        let isShadow: (Int, Int) -> Bool = { $0 + $1 < Self.side }
        let isHighlight: (Int, Int) -> Bool = { !isShadow($0, $1) }

        #expect(meanChannel(graded, channel: 0, where: isHighlight) > meanChannel(baseline, channel: 0, where: isHighlight) + 4)
        for channel in 0..<3 {
            #expect(abs(meanChannel(graded, channel: channel, where: isShadow) - meanChannel(baseline, channel: channel, where: isShadow)) <= 3)
        }
    }

    @Test func masterTintIsUniform() throws {
        let context = try makeContext()
        let input = try makeSplitImage(low: 30, high: 220)
        var parameters = DevelopParameters.neutral
        parameters.colorBalance.master = ColorBalanceComponent(hue: 200, saturation: 60)

        let baseline = try renderRGBA(input, context: context)
        let graded = try renderRGBA(
            DevelopPipeline.apply(
                parameters,
                to: input,
                isRAW: false,
                usesToneMaskedColorGrading: true
            ),
            context: context
        )
        let isShadow: (Int, Int) -> Bool = { $0 + $1 < Self.side }
        let isHighlight: (Int, Int) -> Bool = { !isShadow($0, $1) }
        let shadowDelta = meanChannel(graded, channel: 2, where: isShadow) - meanChannel(baseline, channel: 2, where: isShadow)
        let highlightDelta = meanChannel(graded, channel: 2, where: isHighlight) - meanChannel(baseline, channel: 2, where: isHighlight)

        #expect(abs(shadowDelta - highlightDelta) < 6)
    }

    @Test func legacyPathUnchanged() throws {
        let context = try makeContext()
        let input = try makeTestImage()
        var parameters = DevelopParameters.neutral
        parameters.colorBalance.master = ColorBalanceComponent(hue: 40, saturation: 40)

        let firstLegacy = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false), context: context
        )
        let secondLegacy = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false), context: context
        )
        let graded = try renderRGBA(
            DevelopPipeline.apply(
                parameters,
                to: input,
                isRAW: false,
                usesToneMaskedColorGrading: true
            ),
            context: context
        )

        #expect(firstLegacy == secondLegacy)
        #expect(firstLegacy != graded)
    }

    @Test func hasAnyEffectTracksNeutrality() {
        #expect(DevelopPipeline.hasAnyEffect(.neutral) == false)

        var parameters = DevelopParameters.neutral
        parameters.exposure = 0.5
        #expect(DevelopPipeline.hasAnyEffect(parameters))
    }

    // MARK: - 手動レンズ補正

    @Test func manualLensDistortionAppliesOnlyWhenEnabled() throws {
        let context = try makeContext()
        let input = try makeTestImage()
        var parameters = DevelopParameters.neutral
        parameters.lensDistortion = 60

        let withoutCorrection = try renderRGBA(
            DevelopPipeline.apply(parameters, to: input, isRAW: false), context: context
        )
        let withCorrection = try renderRGBA(
            DevelopPipeline.apply(
                parameters, to: input, isRAW: false, applyManualLensCorrection: true
            ),
            context: context
        )

        #expect(maxAbsoluteDifference(withoutCorrection, withCorrection) > 0)
    }

    @Test func zeroManualLensCorrectionIsIdentity() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        let withoutCorrection = try renderRGBA(
            DevelopPipeline.apply(.neutral, to: input, isRAW: false), context: context
        )
        let withCorrection = try renderRGBA(
            DevelopPipeline.apply(
                .neutral, to: input, isRAW: false, applyManualLensCorrection: true
            ),
            context: context
        )

        #expect(maxAbsoluteDifference(withoutCorrection, withCorrection) <= 2)
    }

    @Test func manualLensCorrectionFollowsCallerProvidedApplicability() throws {
        let context = try makeContext()
        let input = try makeTestImage()
        var parameters = DevelopParameters.neutral
        parameters.lensDistortion = 60

        let skipped = try renderRGBA(
            DevelopPipeline.apply(
                parameters, to: input, isRAW: true, applyManualLensCorrection: false
            ),
            context: context
        )
        let applied = try renderRGBA(
            DevelopPipeline.apply(
                parameters, to: input, isRAW: true,
                applyManualLensCorrection: true
            ),
            context: context
        )
        let baseline = try renderRGBA(input, context: context)

        #expect(maxAbsoluteDifference(skipped, baseline) <= 2)
        #expect(maxAbsoluteDifference(applied, baseline) > 0)
    }

    // MARK: - 色管理（v3 Phase 1: ガンマ空間ブラケット）

    /// 恒等トーンカーブを足しても、コントラスト単独の結果を（ほぼ）変えない。
    /// ガンマ空間ブラケットの入口/出口変換が可逆であることの回帰ガード。
    @Test func identityToneCurveInsidePerceptualBracketIsHarmless() throws {
        let context = try makeContext()
        let input = try makeTestImage()

        var contrastOnly = DevelopParameters.neutral
        contrastOnly.contrast = 40

        var withIdentityCurve = contrastOnly
        withIdentityCurve.toneCurveRGB = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)]

        let a = try renderRGBA(DevelopPipeline.apply(contrastOnly, to: input, isRAW: false), context: context)
        let b = try renderRGBA(DevelopPipeline.apply(withIdentityCurve, to: input, isRAW: false), context: context)
        #expect(maxAbsoluteDifference(a, b) <= 4)
    }

    /// コントラスト +50 単独と、同程度の S 字トーンカーブは、中間調を同じ向きへ動かす。
    /// v3 Phase 1 前はコントラスト（リニア）とトーンカーブ（sRGB）が別空間で評価され、
    /// 中間調の移動方向が食い違う場合があった。
    @Test func contrastAndSCurveToneCurveAgreeOnMidtoneDirection() throws {
        let context = try makeContext()
        // 中間グレー付近（sRGB 96 と 160）の 2 パッチ。
        let input = try makeSplitImage(low: 96, high: 160)
        let baseline = try renderRGBA(input, context: context)

        var contrast = DevelopParameters.neutral
        contrast.contrast = 50

        var sCurve = DevelopParameters.neutral
        sCurve.toneCurveRGB = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.25, y: 0.18),
            CurvePoint(x: 0.5, y: 0.5),
            CurvePoint(x: 0.75, y: 0.82),
            CurvePoint(x: 1, y: 1)
        ]

        let byContrast = try renderRGBA(DevelopPipeline.apply(contrast, to: input, isRAW: false), context: context)
        let byCurve = try renderRGBA(DevelopPipeline.apply(sCurve, to: input, isRAW: false), context: context)

        // 低パッチ（左上）と高パッチ（右下）の代表画素を比較する。
        let lowIndex = 0
        let highIndex = (Self.side - 1) * Self.side * 4 + (Self.side - 1) * 4
        for channel in 0..<3 {
            let baseLow = Int(baseline[lowIndex + channel])
            let baseHigh = Int(baseline[highIndex + channel])
            let contrastLowDelta = Int(byContrast[lowIndex + channel]) - baseLow
            let curveLowDelta = Int(byCurve[lowIndex + channel]) - baseLow
            let contrastHighDelta = Int(byContrast[highIndex + channel]) - baseHigh
            let curveHighDelta = Int(byCurve[highIndex + channel]) - baseHigh
            // 低パッチは両方下げ、高パッチは両方上げる（符号一致）。
            #expect(contrastLowDelta <= 0 && curveLowDelta <= 0)
            #expect(contrastHighDelta >= 0 && curveHighDelta >= 0)
        }
    }

    /// sRGB で対称な 2 値（64 と 192、中央 128 対称）にコントラストを掛けると、
    /// ガンマ空間評価により暗部が下がる量と明部が上がる量が概ね釣り合う。
    @Test func contrastExpandsRoughlySymmetricallyAroundMidGrayInGammaSpace() throws {
        let context = try makeContext()
        let input = try makeSplitImage(low: 64, high: 192)
        let baseline = try renderRGBA(input, context: context)

        var contrast = DevelopParameters.neutral
        contrast.contrast = 60
        let boosted = try renderRGBA(DevelopPipeline.apply(contrast, to: input, isRAW: false), context: context)

        let lowIndex = 0
        let highIndex = (Self.side - 1) * Self.side * 4 + (Self.side - 1) * 4
        let downShift = Double(Int(baseline[lowIndex]) - Int(boosted[lowIndex]))    // 正で暗くなった
        let upShift = Double(Int(boosted[highIndex]) - Int(baseline[highIndex]))    // 正で明るくなった

        #expect(downShift > 4)
        #expect(upShift > 4)
        // 完全対称は期待しないが、片側だけ極端に動くことはない（比 0.5〜2.0）。
        #expect(downShift / upShift > 0.5 && downShift / upShift < 2.0)
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
