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

    /// 選択中レイヤーが放射状グラデーションなら、その ID と形状。
    private var selectedRadial: (id: UUID, mask: RadialGradientMask)? {
        guard let id = developViewModel.selectedMaskLayerID,
              let layer = developViewModel.maskLayers.first(where: { $0.id == id }),
              case .radialGradient(let mask) = layer.source else { return nil }
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

                if let selectedRadial {
                    radialHandles(id: selectedRadial.id, mask: selectedRadial.mask, geometry: maskGeometry)
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

        MaskGradientHandleView(
            endpoint: .start,
            position: startPoint,
            onDrag: { update(id: id, endpoint: .start, to: geometry.basePoint(fromDisplay: $0)) },
            onAdjust: { update(id: id, endpoint: .start, to: geometry.basePoint(fromDisplay: startPoint.shiftedX(by: $0))) }
        )
        MaskGradientHandleView(
            endpoint: .end,
            position: endPoint,
            onDrag: { update(id: id, endpoint: .end, to: geometry.basePoint(fromDisplay: $0)) },
            onAdjust: { update(id: id, endpoint: .end, to: geometry.basePoint(fromDisplay: endPoint.shiftedX(by: $0))) }
        )
    }

    /// 放射状グラデーションの外周（近似楕円）と、中心・境界の 2 ハンドル。
    ///
    /// `MaskImageGenerator` は extent の実ピクセル短辺を基準に半径を換算するため、
    /// 正規化座標のまま円・楕円を描くと非正方形画像で歪む。`geometry.baseAspectRatio`
    /// でベース空間のピクセル比へ変換してから角度・半径を計算し、実際の赤い可視化画像の
    /// 輪郭と一致させる。
    @ViewBuilder
    private func radialHandles(
        id: UUID,
        mask: RadialGradientMask,
        geometry: MaskGeometry
    ) -> some View {
        let centerPoint = geometry.displayPoint(fromBase: mask.center)
        let boundaryPoint = geometry.displayPoint(fromBase: radialBoundaryBasePoint(mask, baseAspectRatio: geometry.baseAspectRatio))

        Path { path in
            let steps = 72
            for step in 0...steps {
                let angle = Double(step) / Double(steps) * 2 * .pi
                let point = geometry.displayPoint(
                    fromBase: radialOutlineBasePoint(mask, at: angle, baseAspectRatio: geometry.baseAspectRatio)
                )
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        .stroke(Color.onViewerCanvas.opacity(0.7), lineWidth: 1.5)
        .allowsHitTesting(false)

        MaskGradientHandleView(
            endpoint: .center,
            position: centerPoint,
            onDrag: { location in
                updateRadial(id: id) { $0.center = geometry.basePoint(fromDisplay: location) }
            },
            onAdjust: { direction in
                let shifted = geometry.basePoint(fromDisplay: centerPoint.shiftedX(by: direction))
                updateRadial(id: id) { $0.center = shifted }
            }
        )
        MaskGradientHandleView(
            endpoint: .radius,
            position: boundaryPoint,
            onDrag: { location in
                let base = geometry.basePoint(fromDisplay: location)
                let baseAspectRatio = geometry.baseAspectRatio
                updateRadial(id: id) { mask in
                    // 境界ハンドルは回転前のx軸上（角度0）の点なので、aspectRatioの影響を
                    // 受けない。正規化座標のベクトルをベース空間のピクセル比へ換算してから
                    // 長さ・角度を求める（radialOutlineBasePointの逆変換）。
                    let baseRatio = baseAspectRatio.isFinite && baseAspectRatio > 0 ? Double(baseAspectRatio) : 1
                    let pixelWidth = baseRatio >= 1 ? baseRatio : 1
                    let pixelHeight = baseRatio >= 1 ? 1 : 1 / baseRatio
                    let dxPixel = (base.x - mask.center.x) * pixelWidth
                    let dyPixel = (base.y - mask.center.y) * pixelHeight
                    let length = (dxPixel * dxPixel + dyPixel * dyPixel).squareRoot()
                    guard length > 0 else { return }
                    mask.radius = length
                    mask.rotationDegrees = atan2(dyPixel, dxPixel) * 180 / .pi
                }
            },
            onAdjust: { direction in
                updateRadial(id: id) { mask in
                    mask.radius = max(0.01, mask.radius + Double(direction) * 0.01)
                }
            }
        )
    }

    /// 回転前の基準ベクトル `(radius, 0)` を `rotationDegrees` だけ回した点（ベース空間は y 下向きなので
    /// 標準の回転行列が時計回りになる）。
    private func radialBoundaryBasePoint(_ mask: RadialGradientMask, baseAspectRatio: CGFloat) -> NormalizedPoint {
        radialOutlineBasePoint(mask, at: 0, baseAspectRatio: baseAspectRatio)
    }

    private func radialOutlineBasePoint(
        _ mask: RadialGradientMask,
        at angle: Double,
        baseAspectRatio: CGFloat
    ) -> NormalizedPoint {
        let aspect = mask.aspectRatio > 0 ? mask.aspectRatio : 1
        // ベース空間のピクセル寸法を「短辺 = 1」に正規化した仮想ピクセル座標系。
        // MaskImageGenerator は extent の実ピクセル短辺基準で半径を換算するため、
        // ここでも同じ基準で楕円化・回転してから正規化座標へ戻す。
        let baseRatio = baseAspectRatio.isFinite && baseAspectRatio > 0 ? Double(baseAspectRatio) : 1
        let pixelWidth = baseRatio >= 1 ? baseRatio : 1
        let pixelHeight = baseRatio >= 1 ? 1 : 1 / baseRatio

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

    private func updateRadial(id: UUID, _ transform: (inout RadialGradientMask) -> Void) {
        developViewModel.updateMask(id: id) { layer in
            guard case .radialGradient(var mask) = layer.source else { return }
            transform(&mask)
            layer.source = .radialGradient(mask)
        }
    }

    // 確定済みトリミングの外へ出る配置も許容するのでクランプしない（実装プラン §1.5.3）
    private func update(id: UUID, endpoint: MaskGradientEndpoint, to point: NormalizedPoint) {
        developViewModel.updateMask(id: id) { layer in
            guard case .linearGradient(var mask) = layer.source else { return }
            switch endpoint {
            case .start: mask.start = point
            case .end: mask.end = point
            case .center, .radius: return   // 放射状専用。線形グラデーションには来ない
            }
            layer.source = .linearGradient(mask)
        }
    }
}

// MARK: - Handle

enum MaskGradientEndpoint {
    case start, end
    /// 放射状グラデーションの中心。
    case center
    /// 放射状グラデーションの外周。ドラッグで半径と回転を同時に操作する。
    case radius

    var accessibilityLabel: LocalizedStringKey {
        switch self {
        case .start: "a11y.mask.handle.start"
        case .end: "a11y.mask.handle.end"
        case .center: "a11y.mask.handle.center"
        case .radius: "a11y.mask.handle.radius"
        }
    }
}

private struct MaskGradientHandleView: View {
    let endpoint: MaskGradientEndpoint
    let position: CGPoint
    let onDrag: (CGPoint) -> Void
    /// VoiceOver / キーボードの増減操作。`+1` / `-1` が渡る。
    let onAdjust: (CGFloat) -> Void

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
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onAdjust(1)
            case .decrement: onAdjust(-1)
            @unknown default: break
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onDrag(value.location) }
        )
    }
}

private extension CGPoint {
    /// ハンドルの 1 ステップ（表示座標 4pt）分だけ x を動かした点。
    func shiftedX(by direction: CGFloat) -> CGPoint {
        CGPoint(x: x + direction * 4, y: y)
    }
}
