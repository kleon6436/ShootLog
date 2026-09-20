import SwiftUI

/// マスク編集モード中にビューアへ重ねるオーバーレイ。
///
/// 下敷きは回転・トリミング焼き込み済みの現像プレビューなので、座標変換は `MaskGeometry` に
/// 委ね、ここではその `imageFrame` を使って配置するだけにする。マスク可視化画像もプレビューと
/// 同じ幾何・同じ画素寸法で返ってくるため、同じ矩形へ敷く。
struct MaskEditOverlayView: View {
    let developViewModel: DevelopViewModel
    let containerSize: CGSize
    let rotation: Int
    let cropRect: CGRect?

    private var maskGeometry: MaskGeometry? {
        guard let previewImageSize = developViewModel.previewImage?.size else { return nil }
        return MaskGeometry(
            previewImageSize: previewImageSize,
            containerSize: containerSize,
            rotation: rotation,
            cropRect: cropRect
        )
    }

    /// 選択中レイヤーが線形グラデーションなら、その ID と端点。
    private var selectedGradient: (id: UUID, mask: LinearGradientMask)? {
        guard let id = developViewModel.selectedMaskLayerID,
              let layer = developViewModel.maskLayers.first(where: { $0.id == id }),
              case .linearGradient(let mask) = layer.source else { return nil }
        return (id, mask)
    }

    var body: some View {
        if let maskGeometry {
            ZStack {
                if let overlay = developViewModel.maskOverlayImage {
                    Image(nsImage: overlay)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: maskGeometry.imageFrame.width, height: maskGeometry.imageFrame.height)
                        .position(x: maskGeometry.imageFrame.midX, y: maskGeometry.imageFrame.midY)
                        .opacity(0.55)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if let selectedGradient {
                    gradientHandles(id: selectedGradient.id, mask: selectedGradient.mask, geometry: maskGeometry)
                }
            }
        }
    }

    @ViewBuilder
    private func gradientHandles(
        id: UUID,
        mask: LinearGradientMask,
        geometry: MaskGeometry
    ) -> some View {
        let startPoint = geometry.displayPoint(fromBase: mask.start)
        let endPoint = geometry.displayPoint(fromBase: mask.end)

        Path { path in
            path.move(to: startPoint)
            path.addLine(to: endPoint)
        }
        .stroke(Color.onViewerCanvas.opacity(0.7), lineWidth: 1.5)
        .allowsHitTesting(false)

        MaskGradientHandleView(endpoint: .start, position: startPoint) { location in
            update(id: id, endpoint: .start, to: geometry.basePoint(fromDisplay: location))
        }
        MaskGradientHandleView(endpoint: .end, position: endPoint) { location in
            update(id: id, endpoint: .end, to: geometry.basePoint(fromDisplay: location))
        }
    }

    // 確定済みトリミングの外へ出る配置も許容するのでクランプしない（実装プラン §1.5.3）
    private func update(id: UUID, endpoint: MaskGradientEndpoint, to point: NormalizedPoint) {
        developViewModel.updateMask(id: id) { layer in
            guard case .linearGradient(var mask) = layer.source else { return }
            switch endpoint {
            case .start: mask.start = point
            case .end: mask.end = point
            }
            layer.source = .linearGradient(mask)
        }
    }
}

// MARK: - Handle

enum MaskGradientEndpoint {
    case start, end

    var accessibilityLabel: LocalizedStringKey {
        switch self {
        case .start: "a11y.mask.handle.start"
        case .end: "a11y.mask.handle.end"
        }
    }
}

private struct MaskGradientHandleView: View {
    let endpoint: MaskGradientEndpoint
    let position: CGPoint
    let onDrag: (CGPoint) -> Void

    var body: some View {
        ZStack {
            Color.clear.frame(width: 36, height: 36)  // 大きいタップ領域
            Circle()
                .fill(Color.onViewerCanvas)
                .frame(width: 12, height: 12)
                .elevation(.card)
        }
        .position(position)
        .accessibilityLabel(endpoint.accessibilityLabel)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onDrag(value.location) }
        )
    }
}
