import SwiftUI

// トリミング選択オーバーレイ。正規化座標（0.0〜1.0）でクロップ矩形を返す
struct CropOverlayView: View {
    @State private var vm: CropViewModel
    let onApply: (CGRect) -> Void
    let onCancel: () -> Void

    init(
        initialRect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
        onApply: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._vm = State(initialValue: CropViewModel(initialRect: initialRect))
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pixRect = vm.toPixel(in: size)

            ZStack {
                // クロップ外の半透明マスク（クロップ領域は透明に抜く）
                Canvas { ctx, canvasSize in
                    ctx.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(.cropMask))
                    ctx.blendMode = .clear
                    // blendMode が .clear のため描画色は使われずアルファのみが抜かれる。
                    // ここの .black はAPIが色を要求するためのプレースホルダで、外観追従の対象ではない
                    ctx.fill(Path(pixRect), with: .color(.black))
                }
                .allowsHitTesting(false)

                // クロップ枠
                Rectangle()
                    .strokeBorder(Color.onViewerCanvas, lineWidth: 1.5)
                    .frame(width: pixRect.width, height: pixRect.height)
                    .position(x: pixRect.midX, y: pixRect.midY)
                    .allowsHitTesting(false)

                // 三分割ガイドライン
                Path { p in
                    let w3 = pixRect.width / 3
                    let h3 = pixRect.height / 3
                    [w3, w3 * 2].forEach { offset in
                        p.move(to: CGPoint(x: pixRect.minX + offset, y: pixRect.minY))
                        p.addLine(to: CGPoint(x: pixRect.minX + offset, y: pixRect.maxY))
                    }
                    [h3, h3 * 2].forEach { offset in
                        p.move(to: CGPoint(x: pixRect.minX, y: pixRect.minY + offset))
                        p.addLine(to: CGPoint(x: pixRect.maxX, y: pixRect.minY + offset))
                    }
                }
                .stroke(Color.onViewerCanvas.opacity(0.3), lineWidth: 0.5)
                .allowsHitTesting(false)

                // コーナーハンドル（4 隅）
                ForEach(CropCorner.allCases, id: \.self) { corner in
                    CropHandleView(
                        corner: corner,
                        pixRect: pixRect,
                        containerSize: size,
                        vm: vm
                    )
                }

                // 適用 / キャンセルボタン
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Button("common.cancel") { onCancel() }
                            .buttonStyle(CropActionButtonStyle(isPrimary: false))
                        Button("crop.apply") { onApply(vm.normalizedRect) }
                            .buttonStyle(CropActionButtonStyle(isPrimary: true))
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }
}

// MARK: - Corner Handle

enum CropCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

private struct CropHandleView: View {
    let corner: CropCorner
    let pixRect: CGRect
    let containerSize: CGSize
    let vm: CropViewModel

    var handlePosition: CGPoint {
        switch corner {
        case .topLeft:     CGPoint(x: pixRect.minX, y: pixRect.minY)
        case .topRight:    CGPoint(x: pixRect.maxX, y: pixRect.minY)
        case .bottomLeft:  CGPoint(x: pixRect.minX, y: pixRect.maxY)
        case .bottomRight: CGPoint(x: pixRect.maxX, y: pixRect.maxY)
        }
    }

    var body: some View {
        ZStack {
            Color.clear.frame(width: 36, height: 36)  // 大きいタップ領域
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.onViewerCanvas)
                .frame(width: 12, height: 12)
                .elevation(.card)
        }
        .position(handlePosition)
        .accessibilityLabel(cropHandleAccessibilityLabel)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    vm.applyDrag(corner: corner, location: value.location, containerSize: containerSize)
                }
        )
    }

    // 語順が言語で変わるため、隅ごとに完結したラベルをローカライズする
    private var cropHandleAccessibilityLabel: LocalizedStringKey {
        switch corner {
        case .topLeft:     "a11y.crop.handle.topLeft"
        case .topRight:    "a11y.crop.handle.topRight"
        case .bottomLeft:  "a11y.crop.handle.bottomLeft"
        case .bottomRight: "a11y.crop.handle.bottomRight"
        }
    }
}

// MARK: - Crop Action Button Style

private struct CropActionButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.onViewerCanvas)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPrimary {
            return Color.accentColor.opacity(isPressed ? 0.8 : 1.0)
        }
        return Color.onViewerCanvas.opacity(isPressed ? 0.3 : 0.2)
    }
}
