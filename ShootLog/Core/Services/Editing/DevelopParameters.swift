import Foundation

/// トーンカーブの制御点。x/y とも正規化座標 0.0〜1.0 を想定する。
struct CurvePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// 恒等カーブ（入力 = 出力）を表す制御点列。
    static let identity: [CurvePoint] = [
        CurvePoint(x: 0, y: 0),
        CurvePoint(x: 1, y: 1)
    ]
}

/// カラー別 HSL 調整の帯域識別子。
///
/// `allCases` の順序は `DevelopParameters` の `hslHue` / `hslSaturation` / `hslLuminance`
/// 配列のインデックスと一対一で対応する（0: red 〜 7: magenta）。この順序は永続化される
/// 配列レイアウトと LUT 生成側の前提を兼ねるため、変更してはならない。
enum HSLBand: String, CaseIterable, Codable, Sendable {
    case red
    case orange
    case yellow
    case green
    case aqua
    case blue
    case purple
    case magenta

    /// 帯域の中心色相（0〜360 度）。HSL LUT 生成側が帯域の三角窓を組み立てる際に使う。
    var centerHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 280
        case .magenta: 320
        }
    }
}

/// RAW 現像 / 非破壊編集の全調整値をまとめた値型。
///
/// ピクセルは保持せず、この値を表示・書き出し時にパイプラインへ渡して適用する。
/// SwiftData には Codable な Data ブロブとして保存されるため、`CodingKeys` は安定した
/// ASCII 文字列で固定し、`init(from:)` は欠損キーを既定値で埋めることで、将来のフィールド
/// 追加後も旧 blob をデコードできるようにしている。
struct DevelopParameters: Codable, Equatable, Sendable {

    // MARK: 基本

    /// 露出補正（EV、範囲目安 -3...3）。他の基本調整と違い EV 単位。
    var exposure: Double = 0
    /// コントラスト（範囲目安 -100...100）。
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var brightness: Double = 0

    // MARK: 色

    /// 色温度。as-shot（撮影時ホワイトバランス）からのオフセット（範囲目安 -100...100）。
    /// schema v3以前の永続値を再現するため残す。新規編集は `whiteBalance` を使う。
    var temperature: Double = 0
    var tint: Double = 0
    var whiteBalance: WhiteBalanceSettings = .neutral
    var vibrance: Double = 0
    var saturation: Double = 0

    // MARK: クリエイティブ調整

    var clarity: Double = 0
    var structure: Double = 0
    var dehaze: Double = 0
    var vignette: Double = 0
    var blackAndWhiteEnabled = false
    /// red / orange / yellow / green / aqua / blue の順。B&W有効時だけ効く。
    var bwMix: [Double] = Array(repeating: 0, count: 6)
    var colorBalance: ColorBalanceSettings = .neutral

    // MARK: トーンカーブ（正規化 0...1 の制御点列。既定は恒等カーブ）

    var toneCurveRGB: [CurvePoint] = CurvePoint.identity
    var toneCurveRed: [CurvePoint] = CurvePoint.identity
    var toneCurveGreen: [CurvePoint] = CurvePoint.identity
    var toneCurveBlue: [CurvePoint] = CurvePoint.identity

    // MARK: カラー別 HSL（8 帯域。`HSLBand.allCases` と同順。各 -100...100）

    var hslHue: [Double] = Array(repeating: 0, count: HSLBand.allCases.count)
    var hslSaturation: [Double] = Array(repeating: 0, count: HSLBand.allCases.count)
    var hslLuminance: [Double] = Array(repeating: 0, count: HSLBand.allCases.count)

    // MARK: ディテール

    var sharpness: Double = 0
    var luminanceNoiseReduction: Double = 0
    var colorNoiseReduction: Double = 0

    // MARK: レンズ補正（RAW のみ）

    /// `CIRAWFilter` のプロファイルベースのレンズ補正（歪曲・周辺光量・色収差）を有効にするか。
    /// RAW かつ `DevelopSettings.schemaVersion` >= 2 のときだけ効く。非 RAW では無視。
    var lensCorrectionEnabled: Bool = false
    /// 手動の歪曲補正量（-100...100）。非 RAW / プロファイル無し RAW 向け。
    /// `DevelopSettings.schemaVersion` >= 2 で適用。version 2 は編集時に 3 へ自動更新される。
    /// `LensCorrectionFilter.corrected` の distortion に対応。
    var lensDistortion: Double = 0
    /// 手動の周辺光量補正量（-100...100）。同上。`corrected` の vignette に対応。
    var lensVignette: Double = 0
    /// 手動の色収差補正量（-100...100）。同上。`corrected` の chromaticAberration に対応。
    var lensChromaticAberration: Double = 0

    /// すべて既定値の中立状態。
    static let neutral = DevelopParameters()

    /// 一切の調整が加えられていないか。
    var isNeutral: Bool { self == .neutral }

    /// 手動レンズ補正のいずれかが効いているか。
    var hasManualLensCorrection: Bool {
        lensDistortion != 0 || lensVignette != 0 || lensChromaticAberration != 0
    }

    /// 指定した帯域の HSL 調整量を取り出す。配列が不正で範囲外の場合は (0, 0, 0) を返す。
    func hslAdjustment(for band: HSLBand) -> (hue: Double, saturation: Double, luminance: Double) {
        guard let index = HSLBand.allCases.firstIndex(of: band),
              hslHue.indices.contains(index),
              hslSaturation.indices.contains(index),
              hslLuminance.indices.contains(index) else {
            return (0, 0, 0)
        }
        return (hslHue[index], hslSaturation[index], hslLuminance[index])
    }
}

// MARK: - 相対適用（プリセットの差分重ね）

extension DevelopParameters {

    /// この調整値の上に `delta` を差分として重ねた結果を返す（プリセットの相対適用）。
    ///
    /// - 加算系（露出・コントラスト・HSL 各帯域・シャープ・ノイズ低減 等）は加算し、
    ///   各パラメータの実用レンジ（露出 ±3 EV、その他 ±100）へクランプする。
    /// - トーンカーブは関数合成: `self` のカーブを適用してから `delta` のカーブを適用した合成カーブ。
    /// - `lensCorrectionEnabled` は OR（`delta` で有効化はできるが無効化はしない）。
    /// - `delta` が中立なら `self` をそのまま返す。加算系のみ可換（トーンカーブ合成は順序に依存）。
    func applying(delta: DevelopParameters) -> DevelopParameters {
        guard !delta.isNeutral else { return self }

        var result = self
        result.exposure = Self.clampExposure(exposure + delta.exposure)
        result.contrast = Self.clampUnit(contrast + delta.contrast)
        result.highlights = Self.clampUnit(highlights + delta.highlights)
        result.shadows = Self.clampUnit(shadows + delta.shadows)
        result.whites = Self.clampUnit(whites + delta.whites)
        result.blacks = Self.clampUnit(blacks + delta.blacks)
        result.brightness = Self.clampUnit(brightness + delta.brightness)

        result.temperature = Self.clampUnit(temperature + delta.temperature)
        result.tint = Self.clampUnit(tint + delta.tint)
        result.whiteBalance = Self.applyingWhiteBalance(base: whiteBalance, delta: delta.whiteBalance)
        result.vibrance = Self.clampUnit(vibrance + delta.vibrance)
        result.saturation = Self.clampUnit(saturation + delta.saturation)

        result.clarity = Self.clampUnit(clarity + delta.clarity)
        result.structure = Self.clampUnit(structure + delta.structure)
        result.dehaze = Self.clampUnit(dehaze + delta.dehaze)
        result.vignette = Self.clampUnit(vignette + delta.vignette)
        result.blackAndWhiteEnabled = blackAndWhiteEnabled || delta.blackAndWhiteEnabled
        result.bwMix = Self.addValues(bwMix, delta.bwMix, count: 6)
        result.colorBalance = delta.colorBalance.isNeutral ? colorBalance : delta.colorBalance

        result.toneCurveRGB = Self.compose(base: toneCurveRGB, then: delta.toneCurveRGB)
        result.toneCurveRed = Self.compose(base: toneCurveRed, then: delta.toneCurveRed)
        result.toneCurveGreen = Self.compose(base: toneCurveGreen, then: delta.toneCurveGreen)
        result.toneCurveBlue = Self.compose(base: toneCurveBlue, then: delta.toneCurveBlue)

        result.hslHue = Self.addBands(hslHue, delta.hslHue)
        result.hslSaturation = Self.addBands(hslSaturation, delta.hslSaturation)
        result.hslLuminance = Self.addBands(hslLuminance, delta.hslLuminance)

        result.sharpness = Self.clampUnit(sharpness + delta.sharpness)
        result.luminanceNoiseReduction = Self.clampUnit(luminanceNoiseReduction + delta.luminanceNoiseReduction)
        result.colorNoiseReduction = Self.clampUnit(colorNoiseReduction + delta.colorNoiseReduction)

        result.lensCorrectionEnabled = lensCorrectionEnabled || delta.lensCorrectionEnabled
        result.lensDistortion = Self.clampUnit(lensDistortion + delta.lensDistortion)
        result.lensVignette = Self.clampUnit(lensVignette + delta.lensVignette)
        result.lensChromaticAberration = Self.clampUnit(lensChromaticAberration + delta.lensChromaticAberration)
        return result
    }

    /// 合成カーブのサンプル数。8bit 入出力に対しては 17 点の等間隔サンプルで十分。
    private static let composeSampleCount = 17

    private static func clampUnit(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        return min(max(value, -100), 100)
    }

    private static func clampExposure(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        return min(max(value, -3), 3)
    }

    /// 8 帯域配列を要素ごとに加算し、各要素を ±100 へクランプする。長さ不一致は 0 埋めで揃える。
    private static func addBands(_ base: [Double], _ delta: [Double]) -> [Double] {
        let count = HSLBand.allCases.count
        return (0..<count).map { index in
            let b = base.indices.contains(index) ? base[index] : 0
            let d = delta.indices.contains(index) ? delta[index] : 0
            return clampUnit(b + d)
        }
    }

    private static func addValues(_ base: [Double], _ delta: [Double], count: Int) -> [Double] {
        (0..<count).map { index in
            let b = base.indices.contains(index) ? base[index] : 0
            let d = delta.indices.contains(index) ? delta[index] : 0
            return clampUnit(b + d)
        }
    }

    private static func applyingWhiteBalance(
        base: WhiteBalanceSettings, delta: WhiteBalanceSettings
    ) -> WhiteBalanceSettings {
        guard delta.mode != .asShot else { return base }
        guard delta.mode == .auto || delta.mode == .custom else { return delta }
        var result = delta
        if delta.mode == .custom, base.mode == .custom {
            result.temperatureKelvin = base.temperatureKelvin + (delta.temperatureKelvin - 6_500)
            result.tint = base.tint + delta.tint
            result.normalize()
        }
        return result
    }

    /// `base` を適用してから `then` を適用した合成カーブの制御点列を返す。
    /// どちらかが恒等ならもう一方をそのまま返す。
    private static func compose(base: [CurvePoint], then next: [CurvePoint]) -> [CurvePoint] {
        if ToneCurve.isIdentity(next) { return base }
        if ToneCurve.isIdentity(base) { return next }

        let n = composeSampleCount
        let baseSamples = ToneCurve.sampled(base, count: n)   // base(x) の等間隔サンプル
        let nextSamples = ToneCurve.sampled(next, count: n)   // next(x) の等間隔サンプル
        let denominator = Double(n - 1)

        return (0..<n).map { index in
            let x = Double(index) / denominator
            let intermediate = baseSamples.indices.contains(index) ? baseSamples[index] : x
            let y = sampleLinear(nextSamples, at: intermediate)   // next(base(x))
            return CurvePoint(x: x, y: min(max(y, 0), 1))
        }
    }

    /// 等間隔サンプル列を 0...1 の位置で線形補間する。
    private static func sampleLinear(_ samples: [Double], at position: Double) -> Double {
        guard samples.count >= 2 else { return position }
        let clamped = min(max(position, 0), 1)
        let scaled = clamped * Double(samples.count - 1)
        let lower = Int(scaled.rounded(.down))
        let upper = min(lower + 1, samples.count - 1)
        let fraction = scaled - Double(lower)
        return samples[lower] * (1 - fraction) + samples[upper] * fraction
    }
}

// MARK: - Codable

extension DevelopParameters {

    /// 永続化形式のキー。ローカライズ対象外の安定 ASCII 文字列で固定する。
    enum CodingKeys: String, CodingKey {
        case exposure
        case contrast
        case highlights
        case shadows
        case whites
        case blacks
        case brightness
        case temperature
        case tint
        case whiteBalance
        case vibrance
        case saturation
        case clarity
        case structure
        case dehaze
        case vignette
        case blackAndWhiteEnabled
        case bwMix
        case colorBalance
        case toneCurveRGB
        case toneCurveRed
        case toneCurveGreen
        case toneCurveBlue
        case hslHue
        case hslSaturation
        case hslLuminance
        case sharpness
        case luminanceNoiseReduction
        case colorNoiseReduction
        case lensCorrectionEnabled
        case lensDistortion
        case lensVignette
        case lensChromaticAberration
    }

    /// HSL 配列を必ず 8 要素へ揃える。不足は 0 埋め、超過は切り捨てる。
    private static func normalizedBands(_ values: [Double]) -> [Double] {
        let expected = HSLBand.allCases.count
        if values.count == expected { return values }
        var result = Array(values.prefix(expected))
        if result.count < expected {
            result.append(contentsOf: Array(repeating: 0, count: expected - result.count))
        }
        return result
    }

    private static func normalizedValues(_ values: [Double], count: Int) -> [Double] {
        var result = Array(values.prefix(count))
        if result.count < count { result.append(contentsOf: repeatElement(0, count: count - result.count)) }
        return result
    }

    /// 空のトーンカーブは恒等カーブへフォールバックさせる。
    private static func normalizedCurve(_ points: [CurvePoint]) -> [CurvePoint] {
        points.isEmpty ? CurvePoint.identity : points
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // try? は既に Optional を返す式に対して層を増やさない（Swift 5+ の flattening）。
        // 欠損キー・型不一致とも既定値へ倒す（将来のフィールド追加でも旧 blob を読めるように）
        func double(_ key: CodingKeys) -> Double {
            (try? container.decodeIfPresent(Double.self, forKey: key)) ?? 0
        }

        func bool(_ key: CodingKeys) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? false
        }

        func curve(_ key: CodingKeys) -> [CurvePoint] {
            guard let points = try? container.decodeIfPresent([CurvePoint].self, forKey: key) else {
                return CurvePoint.identity
            }
            return Self.normalizedCurve(points)
        }

        func bands(_ key: CodingKeys) -> [Double] {
            guard let raw = try? container.decodeIfPresent([Double].self, forKey: key) else {
                return Array(repeating: 0, count: HSLBand.allCases.count)
            }
            return Self.normalizedBands(raw)
        }

        func values(_ key: CodingKeys, count: Int) -> [Double] {
            guard let raw = try? container.decodeIfPresent([Double].self, forKey: key) else {
                return Array(repeating: 0, count: count)
            }
            return Self.normalizedValues(raw, count: count)
        }

        self.init()

        exposure = double(.exposure)
        contrast = double(.contrast)
        highlights = double(.highlights)
        shadows = double(.shadows)
        whites = double(.whites)
        blacks = double(.blacks)
        brightness = double(.brightness)

        temperature = double(.temperature)
        tint = double(.tint)
        whiteBalance = (try? container.decodeIfPresent(WhiteBalanceSettings.self, forKey: .whiteBalance)) ?? .neutral
        whiteBalance.normalize()
        vibrance = double(.vibrance)
        saturation = double(.saturation)
        clarity = double(.clarity)
        structure = double(.structure)
        dehaze = double(.dehaze)
        vignette = double(.vignette)
        blackAndWhiteEnabled = bool(.blackAndWhiteEnabled)
        bwMix = values(.bwMix, count: 6)
        colorBalance = (try? container.decodeIfPresent(ColorBalanceSettings.self, forKey: .colorBalance)) ?? .neutral

        toneCurveRGB = curve(.toneCurveRGB)
        toneCurveRed = curve(.toneCurveRed)
        toneCurveGreen = curve(.toneCurveGreen)
        toneCurveBlue = curve(.toneCurveBlue)

        hslHue = bands(.hslHue)
        hslSaturation = bands(.hslSaturation)
        hslLuminance = bands(.hslLuminance)

        sharpness = double(.sharpness)
        luminanceNoiseReduction = double(.luminanceNoiseReduction)
        colorNoiseReduction = double(.colorNoiseReduction)
        lensCorrectionEnabled = bool(.lensCorrectionEnabled)
        lensDistortion = double(.lensDistortion)
        lensVignette = double(.lensVignette)
        lensChromaticAberration = double(.lensChromaticAberration)
    }
}
