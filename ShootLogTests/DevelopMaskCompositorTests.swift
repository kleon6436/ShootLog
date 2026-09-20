import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import ShootLog

/// マスク合成（`DefaultMaskCompositor`）と、`DevelopPipeline.apply` への統合のテスト。
struct DevelopMaskCompositorTests {

    private static let side = 16

    // MARK: - ヘルパー

    /// 本番と同じ空間（作業空間 linearSRGB / 出力 sRGB）で評価するコンテキスト。
    private func makeContext() throws -> CIContext {
        let working = try #require(CGColorSpace(name: CGColorSpace.linearSRGB))
        let output = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return CIContext(options: [.workingColorSpace: working, .outputColorSpace: output])
    }

    /// 一様グレーの sRGB 画像。露出の効きを平均値で測るため階調を持たせない。
    private func makeFlatImage(value: UInt8 = 64) throws -> CIImage {
        let side = Self.side
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
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

    /// 全面 1 のマスク。`.none` は全面 0 なので反転して使う（グラデーションの端に依存せず測れる）。
    private func makeFullCoverageLayer(
        isEnabled: Bool = true,
        _ adjustments: LocalAdjustments = LocalAdjustments()
    ) -> MaskLayer {
        MaskLayer(
            id: UUID(),
            name: "test",
            source: .none,
            isEnabled: isEnabled,
            isInverted: true,
            adjustments: adjustments
        )
    }

    /// 輝度レンジ生成子のマスクレイヤー。境界を鈍らせないよう `smoothness` は 0 に固定する。
    private func makeLuminanceLayer(
        lower: Double,
        upper: Double,
        _ adjustments: LocalAdjustments = LocalAdjustments()
    ) -> MaskLayer {
        MaskLayer(
            id: UUID(),
            name: "luminance",
            source: .luminanceRange(LuminanceRangeMask(lowerBound: lower, upperBound: upper, smoothness: 0)),
            adjustments: adjustments
        )
    }

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

    private func mean(_ pixels: [UInt8]) -> Double {
        var total = 0.0
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])
            count += 3
        }
        return count > 0 ? total / Double(count) : 0
    }

    // MARK: - 合成セマンティクス

    @Test func layersAccumulateFromBottom() throws {
        let context = try makeContext()
        let input = try makeFlatImage()

        var stacked = DevelopParameters.neutral
        stacked.masks = [
            makeFullCoverageLayer(LocalAdjustments(exposure: 0.5)),
            makeFullCoverageLayer(LocalAdjustments(exposure: 0.5))
        ]

        var single = DevelopParameters.neutral
        single.masks = [makeFullCoverageLayer(LocalAdjustments(exposure: 1.0))]

        let stackedMean = mean(try renderRGBA(
            DevelopPipeline.apply(stacked, to: input, isRAW: false), context: context
        ))
        let singleMean = mean(try renderRGBA(
            DevelopPipeline.apply(single, to: input, isRAW: false), context: context
        ))
        let inputMean = mean(try renderRGBA(input, context: context))

        // 露出はリニア光の乗算なので +0.5EV を 2 枚重ねると +1.0EV と一致する。
        #expect(stackedMean > inputMean + 10)
        #expect(abs(stackedMean - singleMean) < 2)
    }

    /// 「ベース画像へ再適用」誤実装の回帰防止。局所調整はチェーン入力ではなく
    /// 直前までの合成結果へ掛けるため、中立マスクを足しても描画結果は変わらない。
    @Test func globalAdjustmentsSurviveInsideMaskedArea() throws {
        let context = try makeContext()
        let input = try makeFlatImage()

        var withoutMask = DevelopParameters.neutral
        withoutMask.exposure = 2.0

        var withNeutralMask = withoutMask
        withNeutralMask.masks = [makeFullCoverageLayer()]

        let plain = try renderRGBA(
            DevelopPipeline.apply(withoutMask, to: input, isRAW: false), context: context
        )
        let masked = try renderRGBA(
            DevelopPipeline.apply(withNeutralMask, to: input, isRAW: false), context: context
        )

        #expect(mean(plain) > mean(try renderRGBA(input, context: context)) + 20)
        #expect(abs(mean(masked) - mean(plain)) < 1)
    }

    /// グローバルとローカルの露出が加算されること（上のテストの強い版）。
    @Test func localExposureStacksOnTopOfGlobalExposure() throws {
        let context = try makeContext()
        let input = try makeFlatImage(value: 32)

        var globalOnly = DevelopParameters.neutral
        globalOnly.exposure = 1.0

        var combined = globalOnly
        combined.masks = [makeFullCoverageLayer(LocalAdjustments(exposure: 1.0))]

        let globalMean = mean(try renderRGBA(
            DevelopPipeline.apply(globalOnly, to: input, isRAW: false), context: context
        ))
        let combinedMean = mean(try renderRGBA(
            DevelopPipeline.apply(combined, to: input, isRAW: false), context: context
        ))

        #expect(combinedMean > globalMean + 10)
    }

    /// RAW で全体露出を `CIRAWFilter` へ委譲していても、局所露出は標準チェーンで効く。
    @Test func localExposureAppliesWhenGlobalExposureIsDelegatedToRAWDecoder() throws {
        let context = try makeContext()
        let input = try makeFlatImage()

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1.0   // 委譲対象（このチェーンでは適用されない）
        parameters.masks = [makeFullCoverageLayer(LocalAdjustments(exposure: 1.0))]

        let output = DevelopPipeline.apply(
            parameters, to: input, isRAW: true, skipExposureAndWhiteBalance: true
        )

        let inputMean = mean(try renderRGBA(input, context: context))
        let outputMean = mean(try renderRGBA(output, context: context))
        #expect(outputMean > inputMean + 10)
    }

    @Test func emptyMasksLeaveTheChainUnchanged() throws {
        let context = try makeContext()
        let input = try makeFlatImage()

        var parameters = DevelopParameters.neutral
        parameters.contrast = 30

        let output = DevelopPipeline.apply(parameters, to: input, isRAW: false)
        #expect(output.extent == input.extent)
        // masks が空なら追加ループは no-op。中立パラメータは従来どおり入力をそのまま返す。
        let neutral = DevelopPipeline.apply(.neutral, to: input, isRAW: false)
        #expect(mean(try renderRGBA(neutral, context: context)) == mean(try renderRGBA(input, context: context)))
    }

    // MARK: - 輝度レンジマスク

    /// 輝度は「グローバル調整を通した後」の画像から読む。全域を選ぶレンジは全面マスクと同じに、
    /// 外れたレンジは何も起こさない。
    @Test func luminanceRangeLayerReadsGloballyAdjustedImage() throws {
        let context = try makeContext()
        let input = try makeFlatImage(value: 128)

        var globalOnly = DevelopParameters.neutral
        globalOnly.exposure = 0.5

        var fullRange = globalOnly
        fullRange.masks = [makeLuminanceLayer(lower: 0, upper: 1, LocalAdjustments(exposure: 1.0))]

        // グローバル +0.5EV 後のガンマ空間の輝度は約 0.59。ここから外れたレンジは何も選ばない。
        var missedRange = globalOnly
        missedRange.masks = [makeLuminanceLayer(lower: 0.8, upper: 1.0, LocalAdjustments(exposure: 1.0))]

        let globalMean = mean(try renderRGBA(
            DevelopPipeline.apply(globalOnly, to: input, isRAW: false), context: context
        ))
        let fullMean = mean(try renderRGBA(
            DevelopPipeline.apply(fullRange, to: input, isRAW: false), context: context
        ))
        let missedMean = mean(try renderRGBA(
            DevelopPipeline.apply(missedRange, to: input, isRAW: false), context: context
        ))

        #expect(fullMean > globalMean + 10)
        #expect(abs(missedMean - globalMean) < 1)
    }

    /// 各レイヤーはマスクループ開始時点の画像から輝度を読む。`input`（累積結果）から読むと、
    /// 1 枚目の露出で輝度が持ち上がって 2 枚目の選択範囲から外れ、効きが消える。
    @Test func luminanceRangeLayersEvaluateAgainstFixedBaseImage() throws {
        let context = try makeContext()
        let input = try makeFlatImage(value: 128)   // ガンマ空間の輝度 約 0.50

        // 元の輝度は含み、+1EV 後の輝度（ガンマ空間で約 0.69）は含まないレンジ。
        var stacked = DevelopParameters.neutral
        stacked.masks = [
            makeLuminanceLayer(lower: 0.40, upper: 0.60, LocalAdjustments(exposure: 1.0)),
            makeLuminanceLayer(lower: 0.40, upper: 0.60, LocalAdjustments(exposure: 1.0))
        ]

        var singleStep = DevelopParameters.neutral
        singleStep.masks = [makeFullCoverageLayer(LocalAdjustments(exposure: 1.0))]

        var doubleStep = DevelopParameters.neutral
        doubleStep.masks = [makeFullCoverageLayer(LocalAdjustments(exposure: 2.0))]

        let stackedMean = mean(try renderRGBA(
            DevelopPipeline.apply(stacked, to: input, isRAW: false), context: context
        ))
        let singleMean = mean(try renderRGBA(
            DevelopPipeline.apply(singleStep, to: input, isRAW: false), context: context
        ))
        let doubleMean = mean(try renderRGBA(
            DevelopPipeline.apply(doubleStep, to: input, isRAW: false), context: context
        ))

        #expect(abs(stackedMean - doubleMean) < 2)
        #expect(stackedMean > singleMean + 10)
    }

    // MARK: - 持ち上げ済みパラメータの契約

    @Test func liftedParametersKeepGeometryNeutralAndMasksEmpty() {
        var adjustments = LocalAdjustments()
        adjustments.exposure = 1.5
        adjustments.saturation = -40
        adjustments.temperature = 25

        let lifted = DefaultMaskCompositor.lifted(adjustments)

        #expect(lifted.exposure == 1.5)
        #expect(lifted.saturation == -40)
        #expect(lifted.temperature == 25)

        // 契約 1: 幾何系は中立（局所段でレンズ補正が二重に掛からない）。
        #expect(lifted.lensCorrectionEnabled == false)
        #expect(lifted.lensDistortion == 0)
        #expect(lifted.lensVignette == 0)
        #expect(lifted.lensChromaticAberration == 0)
        #expect(lifted.hasManualLensCorrection == false)

        // 契約 2: 再帰の停止条件。
        #expect(lifted.masks.isEmpty)

        // 絶対 Kelvin のホワイトバランスは局所段では使わない（相対オフセット経路のみ）。
        #expect(lifted.whiteBalance == DevelopParameters.neutral.whiteBalance)
    }

    @Test func liftingNeutralAdjustmentsYieldsNeutralParameters() {
        #expect(DefaultMaskCompositor.lifted(LocalAdjustments()).isNeutral)
    }

    /// `hasPerceptualEffect` はグローバル調整の知覚ブラケット要否だけを見る。
    /// masks の条件を足すとグローバル側に不要なブラケットが挟まる（§1.4）。
    @Test func hasPerceptualEffectIgnoresMasks() {
        var parameters = DevelopParameters.neutral
        parameters.masks = [makeFullCoverageLayer(LocalAdjustments(contrast: 50))]
        #expect(DevelopPipeline.hasPerceptualEffect(parameters) == false)
    }

    // MARK: - 構造不変条件（局所 apply の呼び出し回数）

    @Test(arguments: [0, 1, 3])
    func localApplyRunsOncePerEnabledLayer(_ layerCount: Int) throws {
        let input = try makeFlatImage()
        let spy = SpyMaskCompositor()

        var parameters = DevelopParameters.neutral
        parameters.exposure = 0.5   // masks が空のときも isNeutral にならないようにする
        parameters.masks = (0..<layerCount).map { _ in
            makeFullCoverageLayer(LocalAdjustments(exposure: 0.2))
        }

        _ = DevelopPipeline.apply(parameters, to: input, isRAW: false, maskCompositor: spy)
        #expect(spy.callCount == layerCount)
    }

    @Test func disabledLayersAreNotComposed() throws {
        let input = try makeFlatImage()
        let spy = SpyMaskCompositor()

        var parameters = DevelopParameters.neutral
        parameters.masks = [
            makeFullCoverageLayer(isEnabled: false, LocalAdjustments(exposure: 1.0)),
            makeFullCoverageLayer(LocalAdjustments(exposure: 1.0)),
            makeFullCoverageLayer(isEnabled: false, LocalAdjustments(exposure: 1.0))
        ]

        _ = DevelopPipeline.apply(parameters, to: input, isRAW: false, maskCompositor: spy)
        #expect(spy.callCount == 1)
        #expect(spy.composedLayerIDs == [parameters.masks[1].id])
    }
}

/// `composeLayer` の呼び出しを数えつつ、合成自体は既定実装へ委譲するスパイ。
private final class SpyMaskCompositor: MaskCompositing, @unchecked Sendable {

    private let lock = NSLock()
    private let wrapped = DefaultMaskCompositor()
    private var composedIDs: [UUID] = []

    var callCount: Int { lock.withLock { composedIDs.count } }
    var composedLayerIDs: [UUID] { lock.withLock { composedIDs } }

    func composeLayer(
        _ layer: MaskLayer,
        onto input: CIImage,
        baseImage: CIImage,
        baseExtent: CGRect,
        isRAW: Bool,
        maskRasters: [UUID: CGImage],
        cache: DevelopPipelineCache?
    ) -> CIImage {
        lock.withLock { composedIDs.append(layer.id) }
        return wrapped.composeLayer(
            layer,
            onto: input,
            baseImage: baseImage,
            baseExtent: baseExtent,
            isRAW: isRAW,
            maskRasters: maskRasters,
            cache: cache
        )
    }
}
