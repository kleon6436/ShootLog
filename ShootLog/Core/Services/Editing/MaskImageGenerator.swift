import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// `MaskLayer` からマスク画像（グレースケール）を生成する。
///
/// 出力は RGB とアルファのすべてにマスク値 m を持つ premultiplied 画像で、
/// そのまま `CIBlendWithMask`（アルファ基準）へ渡せる。
///
/// 合成順は `MaskLayer` のドキュメントに書かれた契約どおり:
/// ```
/// base  = source が生成するグレースケール（none は全面 0）
/// brush = brushEdits を順に適用（Phase 3 まで常に空）
/// m = clamp(base + brush, 0, 1)
/// m = isInverted ? (1 - m) : m
/// m = m * (density / 100)
/// m = feather > 0 ? gaussianBlur(m, radius) : m
/// m = m.cropped(to: baseExtent)
/// ```
///
/// `CISmoothLinearGradient` などのグラデーションフィルタは infinite extent を返すため、
/// 最後の `cropped(to:)` は必須（プラン §1.2 の規約）。これを省くと feather の
/// `CIGaussianBlur` や `CIBlendWithMask` の extent 推論が壊れる。
///
/// `isEnabled` はここでは見ない。無効なレイヤーを飛ばすのは呼び出し側（パイプライン）の責務。
enum MaskImageGenerator {

    /// feather 100 のときのガウシアン半径。extent の長辺に対する比率で持つことで、
    /// プレビュー縮小とフル解像度で効き方が一致する（`LensCorrectionFilter` と同じ流儀）。
    private static let featherRadiusFraction = 0.08

    /// この絶対値以下の feather / density 差は中立とみなす。
    private static let neutralThreshold = 1e-6

    /// 全面 0（完全透明の黒）。infinite extent。
    private static let zeroImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))

    // MARK: - 公開 API

    /// `layer` のマスク画像を `baseExtent` 基準で生成する。戻り値の extent は必ず `baseExtent` と一致する。
    ///
    /// - Parameters:
    ///   - layer: マスクレイヤー。幾何は §1.5 のベース空間（回転・トリミング前）の正規化座標。
    ///   - baseExtent: マスクを載せる画像の extent（ピクセル座標）。
    static func maskImage(for layer: MaskLayer, baseExtent: CGRect) -> CIImage {
        guard baseExtent.width > 0, baseExtent.height > 0, !baseExtent.isInfinite else {
            return zeroImage.cropped(to: baseExtent)
        }

        var mask = baseImage(for: layer.source, in: baseExtent)
        mask = clampedToUnitInterval(mask)
        if layer.isInverted {
            mask = inverted(mask)
        }
        mask = scaled(mask, by: clampPercent(layer.density) / 100)
        mask = feathered(mask, amount: layer.feather, extent: baseExtent)
        return mask.cropped(to: baseExtent)
    }

    // MARK: - ベース生成子

    /// Phase 1a で実装するのは線形グラデーションのみ。
    /// 放射状（Phase 1b）・AI（Phase 2）・未知の種別（前方互換、§3.5）はいずれも全面 0 を返す。
    private static func baseImage(for source: MaskSource, in extent: CGRect) -> CIImage {
        switch source {
        case .linearGradient(let gradient):
            return linearGradientImage(gradient, in: extent)
        case .none, .radialGradient, .ai, .unrecognized:
            return zeroImage
        }
    }

    private static func linearGradientImage(_ gradient: LinearGradientMask, in extent: CGRect) -> CIImage {
        guard let start = pixelPoint(gradient.start, in: extent),
              let end = pixelPoint(gradient.end, in: extent) else {
            return zeroImage
        }
        // 始点と終点が重なるとグラデーションの向きが定まらない。
        guard hypot(end.x - start.x, end.y - start.y) > neutralThreshold else { return zeroImage }

        let filter = CIFilter.smoothLinearGradient()
        filter.point0 = start
        filter.point1 = end
        filter.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        filter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        return filter.outputImage ?? zeroImage
    }

    /// ベース空間の正規化座標（左上原点）を Core Image のピクセル座標（左下原点）へ写す。
    private static func pixelPoint(_ point: NormalizedPoint, in extent: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(
            x: extent.origin.x + point.x * extent.width,
            y: extent.origin.y + (1 - point.y) * extent.height
        )
    }

    // MARK: - 合成段

    private static func clampedToUnitInterval(_ image: CIImage) -> CIImage {
        let filter = CIFilter.colorClamp()
        filter.inputImage = image
        filter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return filter.outputImage ?? image
    }

    /// m -> 1 - m。`CIColorInvert` はアルファを反転しないので `CIColorMatrix` で 4 成分まとめて反転する。
    private static func inverted(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
    }

    private static func scaled(_ image: CIImage, by factor: Double) -> CIImage {
        guard abs(factor - 1) > neutralThreshold else { return image }
        let f = CGFloat(factor)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: f),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    private static func feathered(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let ratio = clampPercent(amount) / 100
        guard ratio > neutralThreshold else { return image }
        let radius = ratio * featherRadiusFraction * Double(max(extent.width, extent.height))
        guard radius > neutralThreshold else { return image }

        // 枠の外は端の値で埋める。そうしないとガウシアンが画像の縁を無条件に 0 へ引っ張る。
        let source = image.cropped(to: extent).clampedToExtent()
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = source
        filter.radius = Float(radius)
        return filter.outputImage ?? image
    }

    // MARK: - ヘルパー

    private static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }
}
