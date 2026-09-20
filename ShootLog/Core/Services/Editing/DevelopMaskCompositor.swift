import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// ローカル調整（マスク）1 枚分の合成。
///
/// `composeLayer` の呼び出し回数がそのまま局所 `DevelopPipeline.apply` の呼び出し回数と
/// 一致する。テストはスパイ実装を差し込んでこの構造不変条件を観測する。
protocol MaskCompositing: Sendable {

    /// 有効な 1 レイヤー分を合成し、直前までの結果（`input`）へ重ねた結果を返す。
    /// - Parameters:
    ///   - input: 直前までの合成結果。グローバル調整は適用済み（ベース画像ではない）。
    ///   - baseImage: マスクループ開始時点で固定したグローバル調整済み画像。輝度レンジマスクが
    ///     輝度を読む対象。`input` を使うと、下のレイヤーの効果で上のレイヤーの選択範囲がずれる。
    ///   - baseExtent: マスク幾何の基準になるチェーン入力の extent。
    ///   - maskRasters: `AIMaskReference.rasterID` で引ける解決済みラスタ。
    func composeLayer(
        _ layer: MaskLayer,
        onto input: CIImage,
        baseImage: CIImage,
        baseExtent: CGRect,
        isRAW: Bool,
        maskRasters: [UUID: CGImage],
        cache: DevelopPipelineCache?
    ) -> CIImage
}

/// `DevelopPipeline.apply` を局所調整のために再適用し、`CIBlendWithMask` で合成する既定実装
/// （実装プラン §5.3 Option 1）。
struct DefaultMaskCompositor: MaskCompositing {

    func composeLayer(
        _ layer: MaskLayer,
        onto input: CIImage,
        baseImage: CIImage,
        baseExtent: CGRect,
        isRAW: Bool,
        maskRasters: [UUID: CGImage],
        cache: DevelopPipelineCache?
    ) -> CIImage {
        // 局所段では露出・WB を常に標準チェーンで処理する。RAW の全体露出・全体 WB が
        // CIRAWFilter へ委譲されていても、デコーダには局所調整を渡せないため
        // skipExposureAndWhiteBalance を継承すると局所露出が無言で効かなくなる（§1.4）。
        // レンズ補正は幾何変形で、局所段で二重に掛けると前景と背景の画像内容がずれる。
        let adjusted = DevelopPipeline.apply(
            Self.lifted(layer.adjustments),
            to: input,
            isRAW: isRAW,
            cache: cache,
            skipExposureAndWhiteBalance: false,
            applyManualLensCorrection: false,
            usesToneMaskedColorGrading: false,
            asShotWhiteBalance: nil
        )

        let filter = CIFilter.blendWithMask()
        filter.inputImage = adjusted
        filter.backgroundImage = input
        filter.maskImage = Self.maskImage(
            for: layer, baseExtent: baseExtent, maskRasters: maskRasters, sourceImage: baseImage
        )
        return (filter.outputImage ?? input).cropped(to: baseExtent)
    }

    /// `LocalAdjustments` のフィールドだけを持つ `DevelopParameters` を組み立てる。
    ///
    /// 残りは `.neutral` 由来のまま据え置く。ここから 2 つの不変条件が導かれる（§1.4）:
    /// 幾何系（レンズ補正）フィールドが中立なのでレンズ補正の二重適用が起きないこと、
    /// `masks` が空なので `apply` → 合成 → `apply` の再帰が 1 段で止まること。
    static func lifted(_ adjustments: LocalAdjustments) -> DevelopParameters {
        var parameters = DevelopParameters.neutral
        parameters.exposure = adjustments.exposure
        parameters.contrast = adjustments.contrast
        parameters.highlights = adjustments.highlights
        parameters.shadows = adjustments.shadows
        parameters.whites = adjustments.whites
        parameters.blacks = adjustments.blacks
        parameters.saturation = adjustments.saturation
        parameters.vibrance = adjustments.vibrance
        parameters.clarity = adjustments.clarity
        parameters.structure = adjustments.structure
        parameters.sharpness = adjustments.sharpness
        parameters.luminanceNoiseReduction = adjustments.luminanceNoiseReduction
        parameters.colorNoiseReduction = adjustments.colorNoiseReduction
        parameters.temperature = adjustments.temperature
        parameters.tint = adjustments.tint
        return parameters
    }

    /// 解決済みラスタを織り込んだマスク画像。合成と可視化（`renderMaskOverlay`）で
    /// 同じ規則を通すため、ここが唯一の入口になる。
    ///
    /// Phase 1a では `.ai` ソースが `MaskImageGenerator` の時点で全面 0 のため素通しする。
    /// Phase 2 で `rasterID` の解決を足すときも、辞書に無い ID は全面 0（＝レイヤーを描画から
    /// 外す）として扱うこと。黙って全面 1 にすると写真全体へ調整が効いてしまう（§3.2.1）。
    static func maskImage(
        for layer: MaskLayer,
        baseExtent: CGRect,
        maskRasters: [UUID: CGImage],
        sourceImage: CIImage?
    ) -> CIImage {
        MaskImageGenerator.maskImage(for: layer, baseExtent: baseExtent, sourceImage: sourceImage)
    }
}
