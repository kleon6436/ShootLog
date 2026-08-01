import SwiftUI

// トリミング矩形の正規化座標（0.0〜1.0）と座標変換ロジックを保持するViewModel
@Observable
@MainActor
final class CropViewModel {
    var normalizedRect: CGRect

    // ドラッグ時、矩形が反転しないように最小サイズを確保する
    private let minFraction: CGFloat = 0.05

    init(initialRect: CGRect) {
        self.normalizedRect = initialRect
    }

    func toPixel(in size: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * size.width,
            y: normalizedRect.minY * size.height,
            width: normalizedRect.width * size.width,
            height: normalizedRect.height * size.height
        )
    }

    func applyDrag(corner: CropCorner, nx: CGFloat, ny: CGFloat) {
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
}
