import CoreGraphics
import Foundation

/// 放射状マスクの輪郭・境界ハンドルの幾何計算（stateless）。
///
/// ベース空間のピクセル寸法を「短辺 = 1」に正規化した仮想ピクセル座標系で楕円化・回転してから
/// 正規化座標へ戻す。`MaskImageGenerator` は extent の実ピクセル短辺基準で半径を換算するため、
/// オーバーレイ側も同じ基準に揃える。
enum RadialMaskHandleGeometry {

    /// 回転前の基準ベクトル `(radius, 0)` を `rotationDegrees` だけ回した点（ベース空間は y 下向きなので
    /// 標準の回転行列が時計回りになる）。
    static func boundaryPoint(_ mask: RadialGradientMask, baseAspectRatio: CGFloat) -> NormalizedPoint {
        outlinePoint(mask, at: 0, baseAspectRatio: baseAspectRatio)
    }

    static func outlinePoint(
        _ mask: RadialGradientMask,
        at angle: Double,
        baseAspectRatio: CGFloat
    ) -> NormalizedPoint {
        let aspect = mask.aspectRatio > 0 ? mask.aspectRatio : 1
        let (pixelWidth, pixelHeight) = pixelScale(baseAspectRatio: baseAspectRatio)

        // 短辺基準ピクセル空間での楕円境界（回転前）。
        let localXPixel = mask.radius * cos(angle)
        let localYPixel = mask.radius / aspect * sin(angle)

        // ピクセル空間で回転（MaskImageGenerator と同じ「楕円化→回転」の順）。
        let theta = mask.rotationDegrees * .pi / 180
        let rotatedXPixel = localXPixel * cos(theta) - localYPixel * sin(theta)
        let rotatedYPixel = localXPixel * sin(theta) + localYPixel * cos(theta)

        // ピクセル空間から正規化座標へ戻す。
        return NormalizedPoint(
            x: mask.center.x + rotatedXPixel / pixelWidth,
            y: mask.center.y + rotatedYPixel / pixelHeight
        )
    }

    /// 境界ハンドルをベース空間の `point` へ動かしたときの半径と回転角。`boundaryPoint` の逆変換。
    ///
    /// 境界ハンドルは回転前のx軸上（角度0）の点なので、aspectRatioの影響を受けない。
    /// 正規化座標のベクトルをベース空間のピクセル比へ換算してから長さ・角度を求める。
    /// 中心と重なる（長さ 0）場合は角度が決まらないため `nil`。
    static func radiusAndRotation(
        movingBoundaryTo point: NormalizedPoint,
        center: NormalizedPoint,
        baseAspectRatio: CGFloat
    ) -> (radius: Double, rotationDegrees: Double)? {
        let (pixelWidth, pixelHeight) = pixelScale(baseAspectRatio: baseAspectRatio)
        let dxPixel = (point.x - center.x) * pixelWidth
        let dyPixel = (point.y - center.y) * pixelHeight
        let length = (dxPixel * dxPixel + dyPixel * dyPixel).squareRoot()
        guard length > 0 else { return nil }
        return (length, atan2(dyPixel, dxPixel) * 180 / .pi)
    }

    /// 正規化座標 1 あたりの短辺基準ピクセル数（横, 縦）。不正なアスペクト比は 1 とみなす。
    private static func pixelScale(baseAspectRatio: CGFloat) -> (width: Double, height: Double) {
        let baseRatio = baseAspectRatio.isFinite && baseAspectRatio > 0 ? Double(baseAspectRatio) : 1
        let pixelWidth = baseRatio >= 1 ? baseRatio : 1
        let pixelHeight = baseRatio >= 1 ? 1 : 1 / baseRatio
        return (pixelWidth, pixelHeight)
    }
}
