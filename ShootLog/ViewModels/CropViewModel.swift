import SwiftUI

// トリミング矩形の正規化座標（0.0〜1.0）と座標変換ロジックを保持するViewModel。
//
// 正規化座標の基準は「回転適用後に画面へ表示されている画像の矩形」。
// ビューアペイン全体ではなく、レターボックスを除いた画像そのものの領域を 0...1 とする。
// この基準は書き出し側（ImageDevelopmentEngine.applyCrop）が回転後の画像 extent に対して
// 同じ割合で切り抜くことと一致する。
@Observable
@MainActor
final class CropViewModel {
    var normalizedRect: CGRect

    // ドラッグ時、矩形が反転しないように最小サイズを確保する
    private let minFraction: CGFloat = 0.05

    init(initialRect: CGRect) {
        self.normalizedRect = initialRect
    }

    // 正規化矩形を、表示中画像のフレーム（コンテナ座標系）上のピクセル矩形へ変換する。
    func pixelRect(in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + normalizedRect.minX * imageFrame.width,
            y: imageFrame.minY + normalizedRect.minY * imageFrame.height,
            width: normalizedRect.width * imageFrame.width,
            height: normalizedRect.height * imageFrame.height
        )
    }

    // ドラッグ位置（コンテナ座標系）を表示中画像フレーム基準で正規化・クランプしてから、
    // コーナーに応じてクロップ矩形を更新する。
    func applyDrag(corner: CropCorner, location: CGPoint, imageFrame: CGRect) {
        // 画像フレームがまだ確定していない（幅または高さが0）場合、0除算によるNaNを避けて何もしない
        guard imageFrame.width > 0, imageFrame.height > 0 else { return }
        let nx = max(0.0, min(1.0, (location.x - imageFrame.minX) / imageFrame.width))
        let ny = max(0.0, min(1.0, (location.y - imageFrame.minY) / imageFrame.height))
        var r = normalizedRect
        switch corner {
        case .topLeft:
            let x = min(nx, r.maxX - minFraction)
            let y = min(ny, r.maxY - minFraction)
            r = CGRect(x: x, y: y, width: r.maxX - x, height: r.maxY - y)
        case .topRight:
            let y = min(ny, r.maxY - minFraction)
            r = CGRect(x: r.minX, y: y, width: max(minFraction, nx - r.minX), height: r.maxY - y)
        case .bottomLeft:
            let x = min(nx, r.maxX - minFraction)
            r = CGRect(x: x, y: r.minY, width: r.maxX - x, height: max(minFraction, ny - r.minY))
        case .bottomRight:
            r = CGRect(x: r.minX, y: r.minY, width: max(minFraction, nx - r.minX), height: max(minFraction, ny - r.minY))
        }
        normalizedRect = r
    }

    // 表示中画像のフレーム矩形（コンテナ座標系）を求める。
    // rotatedImage のレイアウト（回転後アスペクト比を aspect-fit）と一致させる。
    static func displayedImageFrame(
        imagePixelSize: CGSize,
        rotation: Int,
        in container: CGSize
    ) -> CGRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let isQuarterTurn = ((rotation % 180) + 180) % 180 != 0
        let displayWidth = isQuarterTurn ? imagePixelSize.height : imagePixelSize.width
        let displayHeight = isQuarterTurn ? imagePixelSize.width : imagePixelSize.height
        let scale = min(container.width / displayWidth, container.height / displayHeight)
        let width = displayWidth * scale
        let height = displayHeight * scale
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }
}
