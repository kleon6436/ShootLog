import CoreGraphics
import Foundation

/// 絶対値で保存するホワイトバランス。`asShot` はRAWデコーダーの撮影時設定をそのまま使う。
struct WhiteBalanceSettings: Codable, Equatable, Hashable, Sendable {
    enum Mode: String, CaseIterable, Codable, Hashable, Sendable {
        case asShot, auto, daylight, cloudy, shade, tungsten, fluorescent, flash, custom
    }

    static let minimumTemperature = 2_000.0
    static let maximumTemperature = 12_000.0
    static let neutral = WhiteBalanceSettings()

    var mode: Mode = .asShot
    var temperatureKelvin: Double = 6_500
    var tint: Double = 0

    var hasEffect: Bool { mode != .asShot }

    mutating func normalize() {
        if !temperatureKelvin.isFinite { temperatureKelvin = 6_500 }
        if !tint.isFinite { tint = 0 }
        temperatureKelvin = min(max(temperatureKelvin, Self.minimumTemperature), Self.maximumTemperature)
        tint = min(max(tint, -150), 150)
    }

    static func preset(_ mode: Mode) -> WhiteBalanceSettings {
        let value: (Double, Double)
        switch mode {
        case .asShot: return .neutral
        case .auto, .custom: value = (6_500, 0)
        case .daylight: value = (5_500, 0)
        case .cloudy: value = (6_500, 0)
        case .shade: value = (7_500, 0)
        case .tungsten: value = (3_200, 0)
        case .fluorescent: value = (4_000, 12)
        case .flash: value = (5_500, 0)
        }
        return WhiteBalanceSettings(mode: mode, temperatureKelvin: value.0, tint: value.1)
    }
}

/// 撮影時ホワイトバランスの実測値（RAW）または推定値（非 RAW）。
struct WhiteBalanceSample: Equatable, Sendable {
    var temperatureKelvin: Double
    var tint: Double
    /// 非 RAW のグレーワールド推定など、実測でない場合は `true`。
    var isEstimated: Bool
}

struct ColorBalanceComponent: Codable, Equatable, Hashable, Sendable {
    var hue: Double = 0
    var saturation: Double = 0
    var lightness: Double = 0

    static let neutral = ColorBalanceComponent()
    var isNeutral: Bool { hue == 0 && saturation == 0 && lightness == 0 }

    /// 2つの成分を加算し、実用レンジへクランプする（プリセットの相対適用で使う）。
    /// hue は -180...180、saturation は 0...100、lightness は -100...100 でクランプする。
    func adding(_ other: ColorBalanceComponent) -> ColorBalanceComponent {
        func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
            value.isNaN ? 0 : min(max(value, lower), upper)
        }
        return ColorBalanceComponent(
            hue: clamp(hue + other.hue, -180, 180),
            saturation: clamp(saturation + other.saturation, 0, 100),
            lightness: clamp(lightness + other.lightness, -100, 100)
        )
    }
}

struct ColorBalanceSettings: Codable, Equatable, Hashable, Sendable {
    var master = ColorBalanceComponent()
    var shadows = ColorBalanceComponent()
    var midtones = ColorBalanceComponent()
    var highlights = ColorBalanceComponent()

    static let neutral = ColorBalanceSettings()
    var isNeutral: Bool {
        master.isNeutral && shadows.isNeutral && midtones.isNeutral && highlights.isNeutral
    }

    /// 各トーンレンジの成分を加算し、実用レンジへクランプする。
    func adding(_ other: ColorBalanceSettings) -> ColorBalanceSettings {
        ColorBalanceSettings(
            master: master.adding(other.master),
            shadows: shadows.adding(other.shadows),
            midtones: midtones.adding(other.midtones),
            highlights: highlights.adding(other.highlights)
        )
    }
}

/// デコード済み画像の統計値から再現可能なAuto WBを求める。被写体認識や外部通信は使わない。
enum WhiteBalanceResolver {
    static func automaticSettings(from image: CGImage) -> WhiteBalanceSettings? {
        let width = min(image.width, 256)
        let height = min(image.height, 256)
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Double(bytes[index]) / 255
            let g = Double(bytes[index + 1]) / 255
            let b = Double(bytes[index + 2]) / 255
            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            // 極端な暗部・白飛び・高彩度被写体は推定対象から外す。
            guard maximum > 0.12, maximum < 0.92, maximum - minimum < 0.18 else { continue }
            red += r; green += g; blue += b; count += 1
        }
        guard count > 64 else { return nil }
        let meanR = red / count, meanG = green / count, meanB = blue / count
        let warmth = log(max(meanR, 0.001) / max(meanB, 0.001))
        let tint = log(max(meanG, 0.001) / max((meanR + meanB) / 2, 0.001)) * 90
        var result = WhiteBalanceSettings(mode: .auto, temperatureKelvin: 6_500 + warmth * 2_200, tint: tint)
        result.normalize()
        return result
    }
}

/// Apple標準RAWデコーダーが利用する入力情報。DCP/LCPはこの世代では扱わない。
struct RawDevelopmentProfile: Equatable, Sendable {
    enum DecodeMethod: String, Sendable { case coreImageRAW, imageIO }
    let cameraMake: String?
    let cameraModel: String?
    let decodeMethod: DecodeMethod
    let supportsAsShotWhiteBalance: Bool
    let profileIdentifier: String
    let processVersion: Int
    let failureReason: String?
}
