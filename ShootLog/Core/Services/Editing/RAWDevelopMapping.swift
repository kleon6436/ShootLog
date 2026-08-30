import CoreImage
import Foundation

/// RAW のとき、`DevelopParameters` の露出・ホワイトバランスを `CIRAWFilter` 側
/// （センサー線形空間）で処理するための写像。
///
/// 委譲するのは **露出・色温度・色かぶり・レンズ補正トグルのみ**。ノイズ低減・シャープ・
/// コントラスト等は標準 `CIFilter` チェーン（`DevelopPipeline`）のまま維持する（WYSIWYG 原則）。
///
/// ## ノイズ低減・シャープを委譲しない理由（v3 Phase 6 で実 RAW 検証・却下）
///
/// `CIRAWFilter` の `sharpnessAmount` / `luminanceNoiseReductionAmount` / `detailAmount` は
/// `scaleFactor` を下げた縮小デコードでは効果が急速に失われ、`scaleFactor` ≲ 0.75 では
/// **まったく効かなくなる**（同一パラメータ値で高周波エネルギーが `scaleFactor = 1.0` の
/// 1.7〜2.8 倍から 0.5 以下で 1.00 倍 = 無変化へ崖落ち。実測: NIKON D80 / 1 J2 の RAW 4 枚）。
/// この崖は `scaleFactor` に対して線形でも規則的でもなく、補正係数で吸収できない
/// （縮小プレビューが「無効果」、フル解像度書き出しが「強い効果」になり WYSIWYG が破れる）。
/// `colorNoiseReductionAmount` のみ `scaleFactor` ≥ 0.5 で比較的安定だが、単独委譲は
/// `DevelopPipeline` の NR フィルタ分割が必要なうえ品質寄与が小さいため見送る。
///
/// 値は `CIRAWFilter` のデフォルト（as-shot）からのオフセットとして適用し、機種差・OS 差を吸収する。
enum RAWDevelopMapping {

    /// 色温度 1 単位あたりのケルビン。`DevelopPipeline.applyWhiteBalance` と揃える（±100 で ±3500K）。
    private static let kelvinPerTemperatureUnit: Float = 35
    /// 色かぶり 1 単位あたりの tint オフセット。
    private static let tintPerUnit: Float = 0.5

    /// 露出・WB・レンズ補正トグルを `CIRAWFilter` へ適用する。それ以外のパラメータには触れない。
    static func apply(_ parameters: DevelopParameters, to filter: CIRAWFilter) {
        let exposure = clamp(parameters.exposure, -3, 3)
        if exposure != 0 {
            filter.exposure += Float(exposure)
        }

        let temperature = clamp(parameters.temperature, -100, 100)
        if temperature != 0 {
            filter.neutralTemperature += Float(temperature) * kelvinPerTemperatureUnit
        }

        let tint = clamp(parameters.tint, -100, 100)
        if tint != 0 {
            filter.neutralTint += Float(tint) * tintPerUnit
        }

        // Apple のプロファイルベースのレンズ補正。対応していない RAW では何もしない。
        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = parameters.lensCorrectionEnabled
        }
    }

    /// 委譲対象パラメータ（露出・色温度・色かぶり・レンズ補正）だけのハッシュ。
    /// Stage A キャッシュキーに混ぜ、これらが変わったときだけ RAW を再デコードする。
    static func decodeHash(_ parameters: DevelopParameters) -> Int {
        var hasher = Hasher()
        hasher.combine(parameters.exposure)
        hasher.combine(parameters.temperature)
        hasher.combine(parameters.tint)
        hasher.combine(parameters.lensCorrectionEnabled)
        return hasher.finalize()
    }

    /// 委譲対象パラメータが 1 つでも中立でないか。
    static func hasEffect(_ parameters: DevelopParameters) -> Bool {
        parameters.exposure != 0 || parameters.temperature != 0 || parameters.tint != 0
            || parameters.lensCorrectionEnabled
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        if value.isNaN { return 0 }
        return min(max(value, lower), upper)
    }
}
