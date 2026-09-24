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

    /// ブラシカーソルを描く位置（描画領域ローカル）。ホバーから外れたら `nil`。
    @State private var brushCursorLocation: CGPoint?
    /// ドラッグ 1 回につき `beginBrushStroke` を 1 度だけ呼ぶためのラッチ。
    @State private var isBrushStrokeActive = false

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

    /// 選択中レイヤーが AI マスクなら、その ID と参照。
    private var selectedAIMask: (id: UUID, reference: AIMaskReference)? {
        guard let id = developViewModel.selectedMaskLayerID,
              let layer = developViewModel.maskLayers.first(where: { $0.id == id }),
              case .ai(let reference) = layer.source else { return nil }
        return (id, reference)
    }

    /// ブラシでペイント中の対象レイヤー。削除直後など実体が無い ID は無効として扱う。
    private var brushTargetID: UUID? {
        guard developViewModel.isBrushPaintMode,
              let id = developViewModel.selectedMaskLayerID,
              developViewModel.maskLayers.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// ヒントラベルを画像上端から離す距離。
    private static let hintTopInset: CGFloat = 24

    /// `[` / `]` 1 打あたりのブラシ半径の変化率。太いブラシほど絶対量が増えるよう比率で持つ。
    private static let brushRadiusKeyStepRatio = 0.15

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

                // ペイント中は画像全面がブラシの入力領域になるので、ハンドル類とは排他にする。
                if let brushTargetID {
                    brushPaintLayer(id: brushTargetID, geometry: maskGeometry)
                } else {
                    if let selectedGradient {
                        gradientHandles(id: selectedGradient.id, mask: selectedGradient.mask, geometry: maskGeometry)
                    }

                    if let selectedRadial {
                        radialHandles(id: selectedRadial.id, mask: selectedRadial.mask, geometry: maskGeometry)
                    }

                    if let selectedAIMask {
                        aiRefineLayer(
                            id: selectedAIMask.id,
                            kind: selectedAIMask.reference.kind,
                            geometry: maskGeometry
                        )
                    }
                }
            }
        }
    }

    /// ブラシペイント中に画像全体へ敷く描画領域とカーソル。
    ///
    /// ジェスチャーとホバーは `.frame`/`.position` より **内側**（= 描画矩形そのもの）へ付ける。
    /// `.position` を挟むと報告される座標の基準がコンテナ側へ移り、`imageFrame` の原点を
    /// 足す換算とずれるため。ドラッグ中に呼ぶのは `continueBrushStroke` だけで、`parameters`
    /// を書き換える API（`updateMask` 等）は呼ばない（ドラッグ中に再ラスタライズさせない契約）。
    @ViewBuilder
    private func brushPaintLayer(id: UUID, geometry: MaskGeometry) -> some View {
        let frame = geometry.imageFrame

        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .overlay { brushCursor(geometry: geometry) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): brushCursorLocation = location
                case .ended: brushCursorLocation = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        brushCursorLocation = value.location
                        let point = geometry.basePoint(fromDisplay: CGPoint(
                            x: value.location.x + frame.minX,
                            y: value.location.y + frame.minY
                        ))
                        if isBrushStrokeActive {
                            developViewModel.continueBrushStroke(at: point)
                        } else {
                            isBrushStrokeActive = true
                            developViewModel.beginBrushStroke(at: point, layerID: id)
                        }
                    }
                    .onEnded { _ in
                        isBrushStrokeActive = false
                        developViewModel.endBrushStroke()
                    }
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress("[") {
                adjustBrushRadius(byRatio: -Self.brushRadiusKeyStepRatio)
                return .handled
            }
            .onKeyPress("]") {
                adjustBrushRadius(byRatio: Self.brushRadiusKeyStepRatio)
                return .handled
            }
            // フリーハンド操作自体の VoiceOver 代替は無いが、領域を隠さず「ポインタ操作専用」で
            // あることを伝える（レビュー指摘: 完全非表示だと VoiceOver から存在ごと消えていた）。
            .accessibilityLabel(Text("a11y.mask.brush.paintArea"))
            .accessibilityHint(Text("a11y.mask.brush.paintArea.hint"))

        Text("develop.mask.brush.hint")
            .font(.caption)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.xSmall)
            .background(.regularMaterial, in: Capsule())
            .position(x: frame.midX, y: frame.minY + Self.hintTopInset)
            .allowsHitTesting(false)
    }

    /// マウス位置に重ねる筆先の輪郭。消しゴムは破線にして、色だけに頼らず区別する。
    @ViewBuilder
    private func brushCursor(geometry: MaskGeometry) -> some View {
        if let brushCursorLocation {
            // `BrushMaskRasterizer` は半径をベース空間（回転・トリミング前）の extent 短辺に
            // 対する比率として解釈する。表示中プレビューの短辺をそのまま使うとトリミングで
            // ズームインした写真でカーソルサイズが実際の塗り範囲とずれるため、
            // `MaskGeometry` 経由でクロップ・回転の拡大率を考慮した換算値を使う（レビュー指摘）。
            let diameter = developViewModel.brushRadius * Double(geometry.displayPointsPerBaseShortEdgeUnit) * 2

            Circle()
                .strokeBorder(
                    Color.onViewerCanvas.opacity(0.9),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        dash: developViewModel.isBrushEraserMode ? [4, 3] : []
                    )
                )
                .frame(width: diameter, height: diameter)
                .position(brushCursorLocation)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// ブラシ半径を比率で増減する。VM 側はクランプしないので、許容範囲へ収めるのは UI の責務。
    private func adjustBrushRadius(byRatio ratio: Double) {
        let range = DevelopViewModel.brushRadiusRange
        let updated = developViewModel.brushRadius * (1 + ratio)
        developViewModel.brushRadius = min(max(updated, range.lowerBound), range.upperBound)
    }

    /// AI マスク選択中に画像全体へ敷くクリック領域。クリックした位置のインスタンスだけへ
    /// 絞り込んだマスクを作り直す。線形・放射状のハンドルとは `if case` で排他になるため、
    /// ドラッグジェスチャーと競合しない（輝度レンジは幾何操作を持たないので何も出さない）。
    @ViewBuilder
    private func aiRefineLayer(id: UUID, kind: AIMaskKind, geometry: MaskGeometry) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: geometry.imageFrame.width, height: geometry.imageFrame.height)
            .position(x: geometry.imageFrame.midX, y: geometry.imageFrame.midY)
            .onTapGesture { location in
                // `.onTapGesture` は `.position` より外側に付いているため、`location` は
                // 既にコンテナ座標系で報告される（`MaskGradientHandleView.onDrag` と同じ構造。
                // 座標系のズレバグでオフセットを二重加算していたため撤去、Phase 3レビューで発覚）。
                let point = geometry.basePoint(fromDisplay: location)
                Task { await refineAIMask(id: id, kind: kind, at: point) }
            }
            .disabled(developViewModel.isGeneratingAIMask)
            // フリーハンド操作自体の VoiceOver 代替は無いが、領域を隠さず「ポインタ操作専用」で
            // あることを伝える（`brushPaintLayer` と同じ理由、レビュー指摘）。
            .accessibilityLabel(Text("a11y.mask.ai.refineArea"))
            .accessibilityHint(Text("a11y.mask.ai.refineArea.hint"))

        Text("develop.mask.ai.tapToRefine")
            .font(.caption)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.xSmall)
            .background(.regularMaterial, in: Capsule())
            .position(x: geometry.imageFrame.midX, y: geometry.imageFrame.minY + Self.hintTopInset)
            .allowsHitTesting(false)
    }

    /// 同じ種別・クリック位置指定でマスクを作り直し、成功したときだけ元のレイヤーを捨てる。
    /// 失敗して何も残らない状態を作らないための順序で、`regenerateAIMask` と同じ契約。
    /// カウント比較ではなく戻り値の ID で成否判定する（`regenerateAIMask` と同じ理由）。
    private func refineAIMask(id: UUID, kind: AIMaskKind, at point: NormalizedPoint) async {
        guard await developViewModel.addAIMask(kind: kind, clickPoint: point) != nil else { return }
        developViewModel.removeMask(id: id)
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
        let boundaryPoint = geometry.displayPoint(
            fromBase: RadialMaskHandleGeometry.boundaryPoint(mask, baseAspectRatio: geometry.baseAspectRatio)
        )

        Path { path in
            let steps = 72
            for step in 0...steps {
                let angle = Double(step) / Double(steps) * 2 * .pi
                let point = geometry.displayPoint(
                    fromBase: RadialMaskHandleGeometry.outlinePoint(
                        mask, at: angle, baseAspectRatio: geometry.baseAspectRatio
                    )
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
                    guard let moved = RadialMaskHandleGeometry.radiusAndRotation(
                        movingBoundaryTo: base, center: mask.center, baseAspectRatio: baseAspectRatio
                    ) else { return }
                    mask.radius = moved.radius
                    mask.rotationDegrees = moved.rotationDegrees
                }
            },
            onAdjust: { direction in
                updateRadial(id: id) { mask in
                    mask.radius = max(0.01, mask.radius + Double(direction) * 0.01)
                }
            }
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
            Color.clear.frame(width: 44, height: 44)  // HIG 最小タップ領域（44x44pt）
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
