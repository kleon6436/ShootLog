import CoreGraphics

// FullscreenModeViewのズーム/パン計算ロジック（stateless）。
// ズーム/パンの@State自体はモード往復で永続化させないためView側に残す設計とし、
// ここには引数だけで結果が決まる副作用のない幾何計算のみを置く
enum ZoomPanGeometry {

    // ズーム倍率の下限（fit表示）
    static let minScale: CGFloat = 1.0
    // 画像サイズが未確定な場合に用いる最大ズーム倍率の下限
    static let fallbackMaxScale: CGFloat = 3.0

    // 回転を反映した画像のピクセルサイズ。90度/270度回転時は縦横を入れ替える
    static func rotationAdjustedPixelSize(_ pixelSize: CGSize, rotation: Int) -> CGSize {
        guard rotation % 180 != 0 else { return pixelSize }
        return CGSize(width: pixelSize.height, height: pixelSize.width)
    }

    // fit表示時の画像サイズ。ソースまたはビューポートが未確定ならビューポートをそのまま返す
    static func fittedImageSize(sourcePixelSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return viewportSize }
        let ratio = min(viewportSize.width / sourcePixelSize.width,
                        viewportSize.height / sourcePixelSize.height)
        return CGSize(width: sourcePixelSize.width * ratio, height: sourcePixelSize.height * ratio)
    }

    // 最大ズーム倍率。実際にロード済みの画像がドット等倍になる倍率でキャップし、
    // 768pxサムネイルしか無い状態で過剰に拡大しないようにする（下限は3.0倍）
    static func maxZoomScale(sourcePixelSize: CGSize, fittedImageSize: CGSize) -> CGFloat {
        let sourceWidth = sourcePixelSize.width
        let fitWidth = fittedImageSize.width
        guard sourceWidth > 0, fitWidth > 0 else { return fallbackMaxScale }
        return max(fallbackMaxScale, sourceWidth / fitWidth)
    }

    static func clampedScale(_ scale: CGFloat, maxScale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    // 拡大後の画像が画面外へ流れないよう、各軸のはみ出し量の半分を上限にする。
    // fit倍率以下のときはパンを許可しない
    static func clampedOffset(
        _ offset: CGSize,
        scale: CGFloat,
        fittedImageSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        guard scale > minScale else { return .zero }
        let scaledWidth = fittedImageSize.width * scale
        let scaledHeight = fittedImageSize.height * scale
        let maxX = max(0, (scaledWidth - viewportSize.width) / 2)
        let maxY = max(0, (scaledHeight - viewportSize.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}
