import CoreImage
import Foundation
import Testing

@testable import ShootLog

struct HSLColorCubeTests {

    private static let dimension = HSLColorCube.defaultDimension

    private func zeros() -> [Double] { Array(repeating: 0, count: 8) }

    /// cubeData から格子点 (x=red, y=green, z=blue) の RGB を取り出す。
    private func sample(
        _ data: Data,
        dimension: Int,
        x: Int,
        y: Int,
        z: Int
    ) -> (r: Double, g: Double, b: Double) {
        let floatSize = MemoryLayout<Float>.size
        let base = (((z * dimension) + y) * dimension + x) * 4
        return data.withUnsafeBytes { raw in
            let r = raw.loadUnaligned(fromByteOffset: base * floatSize, as: Float.self)
            let g = raw.loadUnaligned(fromByteOffset: (base + 1) * floatSize, as: Float.self)
            let b = raw.loadUnaligned(fromByteOffset: (base + 2) * floatSize, as: Float.self)
            return (Double(r), Double(g), Double(b))
        }
    }

    /// 検証用の独立した RGB→HSL 実装（本体と同じ式）。
    private func rgbToHSL(
        _ rgb: (r: Double, g: Double, b: Double)
    ) -> (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(rgb.r, rgb.g, rgb.b)
        let minimum = min(rgb.r, rgb.g, rgb.b)
        let lightness = (maximum + minimum) / 2
        guard maximum > minimum else { return (0, 0, lightness) }
        let delta = maximum - minimum
        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)
        var hue: Double
        if maximum == rgb.r {
            hue = (rgb.g - rgb.b) / delta + (rgb.g < rgb.b ? 6 : 0)
        } else if maximum == rgb.g {
            hue = (rgb.b - rgb.r) / delta + 2
        } else {
            hue = (rgb.r - rgb.g) / delta + 4
        }
        return (hue * 60, saturation, lightness)
    }

    // MARK: - 中立

    @Test func neutralParametersProduceIdentityCube() {
        let z = zeros()
        #expect(HSLColorCube.isNeutral(hue: z, saturation: z, luminance: z))
        #expect(HSLColorCube.filter(hue: z, saturation: z, luminance: z) == nil)

        let dim = Self.dimension
        let data = HSLColorCube.cubeData(hue: z, saturation: z, luminance: z, dimension: dim)
        let denominator = Double(dim - 1)
        let probes = [(0, 0, 0), (dim - 1, dim - 1, dim - 1), (5, 12, 20), (dim - 1, 0, dim / 2)]

        for (x, y, zc) in probes {
            let out = sample(data, dimension: dim, x: x, y: y, z: zc)
            #expect(abs(out.r - Double(x) / denominator) < 2.0 / 255)
            #expect(abs(out.g - Double(y) / denominator) < 2.0 / 255)
            #expect(abs(out.b - Double(zc) / denominator) < 2.0 / 255)
        }
    }

    // MARK: - データ長

    @Test func cubeDataLengthMatchesDimensionCubed() {
        let z = zeros()
        for dim in [16, HSLColorCube.defaultDimension] {
            let data = HSLColorCube.cubeData(hue: z, saturation: z, luminance: z, dimension: dim)
            #expect(data.count == dim * dim * dim * 4 * MemoryLayout<Float>.size)
        }

        // 非中立でも長さは変わらない。
        var saturation = zeros()
        saturation[0] = 100
        let adjusted = HSLColorCube.cubeData(hue: z, saturation: saturation, luminance: z, dimension: 16)
        #expect(adjusted.count == 16 * 16 * 16 * 4 * MemoryLayout<Float>.size)
    }

    // MARK: - 単一帯域の彩度

    @Test func singleBandSaturationBoostAffectsOnlyThatHue() {
        let dim = Self.dimension
        let base = zeros()
        var saturation = base
        saturation[0] = 100 // .red

        let data = HSLColorCube.cubeData(
            hue: base, saturation: saturation, luminance: base, dimension: dim
        )
        let denominator = Double(dim - 1)

        // 赤系（部分彩度）の格子点は彩度が上がる。
        let redIn = (r: 20 / denominator, g: 10 / denominator, b: 10 / denominator)
        let redOut = sample(data, dimension: dim, x: 20, y: 10, z: 10)
        #expect(rgbToHSL(redOut).saturation > rgbToHSL(redIn).saturation + 0.05)

        // 緑系・青系の格子点はほぼ不変。
        let greenIn = (r: 10 / denominator, g: 20 / denominator, b: 10 / denominator)
        let greenOut = sample(data, dimension: dim, x: 10, y: 20, z: 10)
        #expect(abs(rgbToHSL(greenOut).saturation - rgbToHSL(greenIn).saturation) < 0.03)

        let blueIn = (r: 10 / denominator, g: 10 / denominator, b: 20 / denominator)
        let blueOut = sample(data, dimension: dim, x: 10, y: 10, z: 20)
        #expect(abs(rgbToHSL(blueOut).saturation - rgbToHSL(blueIn).saturation) < 0.03)
    }

    // MARK: - 単一帯域の色相シフト

    @Test func singleBandHueShiftMovesTargetHueOnly() {
        let dim = Self.dimension
        let base = zeros()
        var hue = base
        hue[5] = 100 // .blue

        let data = HSLColorCube.cubeData(hue: hue, saturation: base, luminance: base, dimension: dim)
        let denominator = Double(dim - 1)

        // 青系格子点の色相は明確にずれる。
        let blueIn = rgbToHSL((r: 10 / denominator, g: 10 / denominator, b: 20 / denominator))
        let blueOut = rgbToHSL(sample(data, dimension: dim, x: 10, y: 10, z: 20))
        #expect(abs(blueOut.hue - blueIn.hue) > 5)

        // 赤系格子点の色相はほぼ不変。
        let redIn = rgbToHSL((r: 20 / denominator, g: 10 / denominator, b: 10 / denominator))
        let redOut = rgbToHSL(sample(data, dimension: dim, x: 20, y: 10, z: 10))
        #expect(abs(redOut.hue - redIn.hue) < 3)
    }

    // MARK: - 数値健全性

    @Test func allOutputsAreFiniteAndInRange() {
        var hue = zeros()
        var saturation = zeros()
        var luminance = zeros()
        for index in 0..<8 {
            hue[index] = Double(index) * 12 - 40
            saturation[index] = Double(7 - index) * 20 - 60
            luminance[index] = index.isMultiple(of: 2) ? 90 : -90
        }

        let dim = 12
        let data = HSLColorCube.cubeData(
            hue: hue, saturation: saturation, luminance: luminance, dimension: dim
        )
        let count = dim * dim * dim * 4
        let floatSize = MemoryLayout<Float>.size

        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let value = raw.loadUnaligned(fromByteOffset: index * floatSize, as: Float.self)
                #expect(value.isFinite)
                #expect(value >= 0 && value <= 1)
            }
        }
    }

    // MARK: - 短い入力配列

    @Test func shortInputArraysDoNotCrash() {
        let short: [Double] = [10, 20, 30]
        #expect(HSLColorCube.isNeutral(hue: [0, 0, 0], saturation: [0], luminance: []))

        let data = HSLColorCube.cubeData(
            hue: short, saturation: short, luminance: short, dimension: 8
        )
        #expect(data.count == 8 * 8 * 8 * 4 * MemoryLayout<Float>.size)
        #expect(HSLColorCube.filter(hue: short, saturation: short, luminance: short, dimension: 8) != nil)
    }
}
