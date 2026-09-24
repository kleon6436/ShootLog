import Foundation

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
        case masks
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
        masks = (try? container.decodeIfPresent([MaskLayer].self, forKey: .masks)) ?? []
    }
}
