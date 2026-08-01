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
                    ctx.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(.black.opacity(0.5)))
                    ctx.blendMode = .clear
                    ctx.fill(Path(pixRect), with: .color(.black))
                }
                .allowsHitTesting(false)

                // クロップ枠
                Rectangle()
                    .strokeBorder(Color.onDarkCanvas, lineWidth: 1.5)
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
                .stroke(Color.onDarkCanvas.opacity(0.3), lineWidth: 0.5)
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
                        Button("キャンセル") { onCancel() }
                            .buttonStyle(CropActionButtonStyle(isPrimary: false))
                        Button("適用") { onApply(vm.normalizedRect) }
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
                .fill(Color.onDarkCanvas)
                .frame(width: 12, height: 12)
                .elevation(.card)
        }
        .position(handlePosition)
        .accessibilityLabel("トリミング範囲の\(accessibilityCornerName)ハンドル")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let nx = max(0.0, min(1.0, value.location.x / containerSize.width))
                    let ny = max(0.0, min(1.0, value.location.y / containerSize.height))
                    vm.applyDrag(corner: corner, nx: nx, ny: ny)
                }
        )
    }

    private var accessibilityCornerName: String {
        switch corner {
        case .topLeft:     "左上"
        case .topRight:    "右上"
        case .bottomLeft:  "左下"
        case .bottomRight: "右下"
        }
    }
}

// MARK: - Crop Action Button Style

private struct CropActionButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.onDarkCanvas)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPrimary {
            return Color.blue.opacity(isPressed ? 0.8 : 1.0)
        }
        return Color.onDarkCanvas.opacity(isPressed ? 0.3 : 0.2)
    }
}
