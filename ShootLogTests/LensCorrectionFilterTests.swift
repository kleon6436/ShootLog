import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import ShootLog

/// レンズ補正フィルタのテスト。
///
/// - Phase 5-1: Metal ワープカーネルのビルド疎通（metallib のバンドル同梱 + `Bundle(for:)` 解決）。
/// - Phase 5-2: 歪曲・周辺光量・色収差の各補正の効き方と、補正量 0 での恒等性。
struct LensCorrectionFilterTests {

    private static let side = 48

    // MARK: - ヘルパー

    private func makeContext() -> CIContext {
        CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    }

    /// 一様グレーの sRGB 画像。周辺光量補正の効きを輝度比で測るのに使う。
    private func makeGrayImage(_ value: UInt8 = 128) throws -> CIImage {
        try makeImage { _, _ in (value, value, value) }
    }

    /// 中央に縦の白線、周囲は黒の画像。色収差補正で R/B のズレが減ることを測るのに使う。
    private func makeCenterLineImage() throws -> CIImage {
        let mid = Self.side / 2
        return try makeImage { x, _ in
            abs(x - mid) <= 1 ? (255, 255, 255) : (0, 0, 0)
        }
    }

    /// 4px 市松模様。全域に高周波成分があり、僅かな幾何変形でも画素値が変わる。
    private func makeCheckerImage() throws -> CIImage {
        try makeImage { x, y in
            ((x / 4) + (y / 4)) % 2 == 0 ? (240, 240, 240) : (16, 16, 16)
        }
    }

    private func makeImage(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CIImage {
        let side = Self.side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                let (r, g, b) = pixel(x, y)
                pixels[index] = r
                pixels[index + 1] = g
                pixels[index + 2] = b
                pixels[index + 3] = 255
            }
        }
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return CIImage(cgImage: cgImage)
    }

    /// CIImage を RGBA8 バイト列へレンダーする。
    private func render(_ image: CIImage) throws -> [UInt8] {
        let side = Self.side
        let context = makeContext()
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        context.render(
            image, toBitmap: &buffer, rowBytes: side * 4, bounds: rect,
            format: .RGBA8, colorSpace: colorSpace
        )
        return buffer
    }

    private func pixel(_ buffer: [UInt8], x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let index = (y * Self.side + x) * 4
        return (Int(buffer[index]), Int(buffer[index + 1]), Int(buffer[index + 2]))
    }

    private func luminance(_ buffer: [UInt8], x: Int, y: Int) -> Double {
        let p = pixel(buffer, x: x, y: y)
        return 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)
    }

    // MARK: - Phase 5-1: ビルド疎通

    @Test func distortionKernelLoadsFromMetallib() {
        #expect(
            LensCorrectionFilter.distortionKernel != nil,
            "\(LensCorrectionFilter.loadFailureReason ?? "理由不明")"
        )
    }

    // MARK: - Phase 5-2: 恒等性

    @Test func correctedIsIdentityAtZero() throws {
        let source = try makeCenterLineImage()
        let before = try render(source)
        let after = try render(
            LensCorrectionFilter.corrected(source, distortion: 0, vignette: 0, chromaticAberration: 0)
        )
        #expect(before == after)
    }

    // MARK: - Phase 5-2: 歪曲

    @Test func distortionWarpsImage() throws {
        let source = try makeCenterLineImage()
        let before = try render(source)
        let after = try render(
            LensCorrectionFilter.corrected(source, distortion: 80, vignette: 0, chromaticAberration: 0)
        )
        // 歪曲補正で少なくとも一部の画素が動く（extent は保たれる）。
        #expect(before != after)
    }

    // MARK: - Phase 5-2: 周辺光量

    @Test func vignetteCorrectionBrightensCorners() throws {
        let source = try makeGrayImage(128)
        let corrected = LensCorrectionFilter.corrected(
            source, distortion: 0, vignette: 100, chromaticAberration: 0
        )
        let buffer = try render(corrected)
        let cornerBefore = 128.0
        let cornerAfter = luminance(buffer, x: 1, y: 1)
        let centerAfter = luminance(buffer, x: Self.side / 2, y: Self.side / 2)
        // 正の補正量で四隅が持ち上がり、中心はほぼ変わらない。
        #expect(cornerAfter > cornerBefore + 2)
        #expect(abs(centerAfter - 128) < 6)
    }

    @Test func vignetteNegativeDarkensCorners() throws {
        let source = try makeGrayImage(160)
        let buffer = try render(LensCorrectionFilter.corrected(
            source, distortion: 0, vignette: -100, chromaticAberration: 0
        ))
        #expect(luminance(buffer, x: 1, y: 1) < 160 - 2)
    }

    // MARK: - Phase 5-2: 色収差

    @Test func chromaticAberrationShiftsChannels() throws {
        let source = try makeCheckerImage()
        let before = try render(source)
        let after = try render(LensCorrectionFilter.corrected(
            source, distortion: 0, vignette: 0, chromaticAberration: 100
        ))
        // R と B を中心基準で逆方向にスケールするので、端に近いほど両チャンネルがずれる。
        // G はスケールしないので中心付近の変化は小さい。少なくとも一部の画素が動く。
        #expect(before != after)

        // 端の列で R と B が別方向に動いていること（横色収差の再合成が効いている）。
        let edgeColumn = Self.side - 3
        let rDelta = (0..<Self.side).reduce(0) {
            $0 + abs(pixel(after, x: edgeColumn, y: $1).r - pixel(before, x: edgeColumn, y: $1).r)
        }
        let bDelta = (0..<Self.side).reduce(0) {
            $0 + abs(pixel(after, x: edgeColumn, y: $1).b - pixel(before, x: edgeColumn, y: $1).b)
        }
        #expect(rDelta > 0 && bDelta > 0)
    }

    @Test func chromaticAberrationKeepsAlphaAtOne() throws {
        let source = try makeGrayImage(128)
        let corrected = LensCorrectionFilter.corrected(
            source, distortion: 0, vignette: 0, chromaticAberration: 100
        )
        // RGBAf で読むと 8bit のクランプで隠れないアルファの過大（旧実装は 3）を検出できる。
        let side = Self.side
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var buffer = [Float](repeating: 0, count: side * side * 4)
        context.render(
            corrected,
            toBitmap: &buffer,
            rowBytes: MemoryLayout<Float>.size * 4 * side,
            bounds: CGRect(x: 0, y: 0, width: side, height: side),
            format: .RGBAf,
            colorSpace: nil
        )
        for (x, y) in [(0, 0), (side / 2, side / 2), (side - 1, side - 1), (0, side - 1)] {
            let index = (y * side + x) * 4
            #expect(abs(buffer[index + 3] - 1) < 0.01, "alpha at (\(x), \(y)) = \(buffer[index + 3])")
            // 一様グレーなので R/G/B はスケールしても揃ったまま（縁も端画素延長で欠けない）。
            #expect(abs(buffer[index] - buffer[index + 1]) < 0.01)
            #expect(abs(buffer[index + 2] - buffer[index + 1]) < 0.01)
        }
    }

    // MARK: - 歪曲の ROI

    @Test func distortionROICoversCornerSamples() {
        let extent = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let normScale = 2 / 1000.0
        // 小さい隅の要求矩形でも、中心からの距離に応じた大きな変位を ROI が含むこと。
        for (k1, k2) in [(0.3, 0.05), (-0.3, -0.05)] {
            let rect = CGRect(x: 990, y: 990, width: 10, height: 10)
            let roi = LensCorrectionFilter.distortionROI(
                for: rect, center: center, normScale: normScale, k1: k1, k2: k2
            )
            for corner in [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
            ] {
                let dx = Double(corner.x - center.x)
                let dy = Double(corner.y - center.y)
                let r2 = (dx * dx + dy * dy) * normScale * normScale
                let factor = 1 + k1 * r2 + k2 * r2 * r2
                let sample = CGPoint(x: Double(center.x) + dx * factor, y: Double(center.y) + dy * factor)
                #expect(roi.contains(sample), "ROI \(roi) does not contain \(sample)")
            }
        }
    }
}
