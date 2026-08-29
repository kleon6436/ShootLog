import CoreImage
import Foundation

/// カラー別 HSL 調整（色相シフト / 彩度 / 輝度）を単一の 3D LUT へ焼き込むユーティリティ。
///
/// Core Image には「色ごとの HSL」を一括で扱う単一フィルタが存在しないため、8 帯域ぶんの
/// 調整を `CIColorCube` / `CIColorCubeWithColorSpace` が要求する `cubeData`
/// （`dimension^3` 個の RGBA Float32、各成分 0...1、アルファ乗算済み、R,G,B,A 順）へ
/// CPU 側で展開する。生成コストは呼び出し側が HSL サブパラメータをキーにキャッシュする前提。
struct HSLColorCube {

    /// 既定のキューブ次元。`dimension^3` 点を評価するため、性能が要求を満たさない場合は
    /// 呼び出し側が 16 などへ落とす（実装プラン §6 リスク #1 のフォールバック）。
    static let defaultDimension = 32

    /// 帯域窓の広がり（度）。中心から ±この範囲でレイズドコサイン窓が 1 → 0 に落ちる。
    /// 隣接帯域と必ずオーバーラップするよう、最大の帯域間隔（60 度）と同じ値にしている。
    private static let bandSupport: Double = 60

    // MARK: - 判定

    /// 全帯域の色相 / 彩度 / 輝度パラメータがすべて 0（許容誤差 1e-6）か。
    ///
    /// true の場合、`DevelopPipeline` は LUT フィルタの挿入自体をスキップできる。
    static func isNeutral(hue: [Double], saturation: [Double], luminance: [Double]) -> Bool {
        let values = normalizedBands(hue) + normalizedBands(saturation) + normalizedBands(luminance)
        return values.allSatisfy { abs($0) <= 1e-6 }
    }

    // MARK: - LUT データ

    /// 8 帯域の HSL 調整を焼き込んだ `cubeData` を返す。
    ///
    /// - Parameters:
    ///   - hue: 帯域ごとの色相シフト量（`HSLBand.allCases` 順、各 -100...100）。
    ///   - saturation: 帯域ごとの彩度調整量（同順・同範囲）。
    ///   - luminance: 帯域ごとの輝度調整量（同順・同範囲）。
    ///   - dimension: キューブ次元（2 未満は 2 へクランプ）。
    /// - Returns: `dimension^3` 個の RGBA Float32 を R,G,B,A 順で並べた `Data`。
    ///   `isNeutral` が true の場合は恒等キューブ（入力 RGB をそのまま返す LUT）。
    static func cubeData(
        hue: [Double],
        saturation: [Double],
        luminance: [Double],
        dimension: Int = defaultDimension
    ) -> Data {
        let dim = clampedDimension(dimension)
        let neutral = isNeutral(hue: hue, saturation: saturation, luminance: luminance)

        let hueBands = normalizedBands(hue)
        let satBands = normalizedBands(saturation)
        let lumBands = normalizedBands(luminance)
        let centers = HSLBand.allCases.map(\.centerHue)

        let pointCount = dim * dim * dim
        var samples = [Float](repeating: 0, count: pointCount * 4)
        let denominator = Double(dim - 1)
        var offset = 0

        // CIColorCube は blue が最外周・red が最内周のループ順を前提とする。
        for zIndex in 0..<dim {
            let blue = Double(zIndex) / denominator
            for yIndex in 0..<dim {
                let green = Double(yIndex) / denominator
                for xIndex in 0..<dim {
                    let red = Double(xIndex) / denominator

                    let output: (r: Double, g: Double, b: Double)
                    if neutral {
                        output = (red, green, blue)
                    } else {
                        output = adjusted(
                            red: red, green: green, blue: blue,
                            centers: centers,
                            hueBands: hueBands, satBands: satBands, lumBands: lumBands
                        )
                    }

                    samples[offset] = Float(sanitizeComponent(output.r)); offset += 1
                    samples[offset] = Float(sanitizeComponent(output.g)); offset += 1
                    samples[offset] = Float(sanitizeComponent(output.b)); offset += 1
                    samples[offset] = 1; offset += 1
                }
            }
        }

        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// sRGB 色空間で動作する `CIColorCubeWithColorSpace` フィルタを生成する。
    ///
    /// `isNeutral` が true の場合は `nil` を返す（呼び出し側でフィルタ挿入をスキップする）。
    static func filter(
        hue: [Double],
        saturation: [Double],
        luminance: [Double],
        dimension: Int = defaultDimension
    ) -> CIFilter? {
        guard !isNeutral(hue: hue, saturation: saturation, luminance: luminance) else { return nil }
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }

        let dim = clampedDimension(dimension)
        let data = cubeData(hue: hue, saturation: saturation, luminance: luminance, dimension: dim)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        filter.setValue(dim, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(colorSpace, forKey: "inputColorSpace")
        return filter
    }

    // MARK: - 調整本体

    private static func adjusted(
        red: Double, green: Double, blue: Double,
        centers: [Double],
        hueBands: [Double], satBands: [Double], lumBands: [Double]
    ) -> (r: Double, g: Double, b: Double) {
        let hsl = rgbToHSL(red: red, green: green, blue: blue)
        let weights = bandWeights(forHue: hsl.hue, centers: centers)

        var effectiveHue = 0.0
        var effectiveSat = 0.0
        var effectiveLum = 0.0
        for index in hueBands.indices {
            effectiveHue += weights[index] * hueBands[index]
            effectiveSat += weights[index] * satBands[index]
            effectiveLum += weights[index] * lumBands[index]
        }

        // -100...100 を実際の効き幅へ。色相は ±30 度、彩度は 0〜2 倍、輝度は 0.5〜1.5 倍。
        var shiftedHue = (hsl.hue + effectiveHue / 100 * 30).truncatingRemainder(dividingBy: 360)
        if shiftedHue < 0 { shiftedHue += 360 }
        let newSaturation = clamp01(hsl.saturation * (1 + effectiveSat / 100))
        let newLightness = clamp01(hsl.lightness * (1 + effectiveLum / 100 * 0.5))

        return hslToRGB(hue: shiftedHue, saturation: newSaturation, lightness: newLightness)
    }

    /// 色相環（wrap-around 考慮）上のレイズドコサイン窓による帯域重み。全帯域和で正規化する。
    private static func bandWeights(forHue hue: Double, centers: [Double]) -> [Double] {
        var weights = centers.map { center -> Double in
            let distance = angularDistance(hue, center)
            guard distance < bandSupport else { return 0 }
            // 中心で 1、境界で 0、両端で微分が連続。隣接帯域と滑らかにオーバーラップする。
            return 0.5 * (1 + cos(.pi * distance / bandSupport))
        }
        let total = weights.reduce(0, +)
        guard total > 1e-9 else { return Array(repeating: 0, count: weights.count) }
        for index in weights.indices { weights[index] /= total }
        return weights
    }

    // MARK: - ヘルパー

    private static func clampedDimension(_ dimension: Int) -> Int {
        max(2, dimension)
    }

    /// 帯域配列を必ず 8 要素へ揃える（不足は 0 埋め、超過は切り捨て）。
    private static func normalizedBands(_ values: [Double]) -> [Double] {
        let expected = HSLBand.allCases.count
        if values.count == expected { return values }
        var result = Array(values.prefix(expected))
        if result.count < expected {
            result.append(contentsOf: Array(repeating: 0, count: expected - result.count))
        }
        return result
    }

    private static func angularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        var delta = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func sanitizeComponent(_ value: Double) -> Double {
        value.isFinite ? clamp01(value) : 0
    }

    // MARK: - HSL 変換（外部依存を増やさないため Foundation の範囲で自前実装）

    private static func rgbToHSL(
        red: Double, green: Double, blue: Double
    ) -> (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2

        guard maximum > minimum else {
            return (0, 0, lightness)
        }

        let delta = maximum - minimum
        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)

        var hue: Double
        if maximum == red {
            hue = (green - blue) / delta + (green < blue ? 6 : 0)
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        return (hue * 60, saturation, lightness)
    }

    private static func hslToRGB(
        hue: Double, saturation: Double, lightness: Double
    ) -> (r: Double, g: Double, b: Double) {
        guard saturation > 0 else {
            return (lightness, lightness, lightness)
        }

        let q = lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        let normalizedHue = hue / 360

        return (
            hueComponent(p: p, q: q, t: normalizedHue + 1.0 / 3.0),
            hueComponent(p: p, q: q, t: normalizedHue),
            hueComponent(p: p, q: q, t: normalizedHue - 1.0 / 3.0)
        )
    }

    private static func hueComponent(p: Double, q: Double, t: Double) -> Double {
        var value = t
        if value < 0 { value += 1 }
        if value > 1 { value -= 1 }
        if value < 1.0 / 6.0 { return p + (q - p) * 6 * value }
        if value < 1.0 / 2.0 { return q }
        if value < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - value) * 6 }
        return p
    }
}
