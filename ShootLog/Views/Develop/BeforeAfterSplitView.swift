import AppKit
import SwiftUI

/// 編集前後の画像を同じ表示矩形に重ね、左側の表示範囲を動かして比較するビュー。
struct BeforeAfterSplitView: View {
    let afterImage: NSImage
    let beforeImage: NSImage?
    @Binding var splitPosition: CGFloat

    @FocusState private var isFocused: Bool

    private let splitStep: CGFloat = 0.02
    private let largeSplitStep: CGFloat = 0.1

    var body: some View {
        GeometryReader { geometry in
            let containerSize = geometry.size
            let imageFrame = CropViewModel.displayedImageFrame(
                imagePixelSize: afterImage.size,
                rotation: 0,
                in: containerSize
            )
            let position = Self.clamped(splitPosition)
            let dividerX = imageFrame.minX + imageFrame.width * position
            let beforeWidth = imageFrame.width * position

            ZStack(alignment: .topLeading) {
                fittedImage(afterImage, in: imageFrame)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                if let beforeImage {
                    fittedImage(beforeImage, in: imageFrame)
                        .frame(width: beforeWidth, height: imageFrame.height, alignment: .leading)
                        .clipped()
                        .position(
                            x: imageFrame.minX + beforeWidth / 2,
                            y: imageFrame.midY
                        )
                }

                Color.clear
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .overlay(alignment: .topLeading) {
                        imageLabel("develop.splitCompare.before")
                            .padding(8)
                    }
                    .overlay(alignment: .topTrailing) {
                        imageLabel("develop.splitCompare.after")
                            .padding(8)
                    }
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                Rectangle()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 2, height: imageFrame.height)
                    .position(x: dividerX, y: imageFrame.midY)

                Circle()
                    .fill(.thinMaterial)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .foregroundStyle(.primary)
                    }
                    .overlay {
                        Circle()
                            .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 2)
                    }
                    .position(x: dividerX, y: imageFrame.midY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        splitPosition = Self.clampedSplitPosition(
                            locationX: value.location.x,
                            in: imageFrame
                        )
                    }
            )
            .focusable()
            .focusEffectDisabled() // システムのフォーカスリング（青枠）を消す。フォーカス表示はハンドルの円で行う
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                let step = press.modifiers.contains(.shift) ? largeSplitStep : splitStep
                if press.key == .leftArrow {
                    updateSplitPosition(by: -step)
                } else {
                    updateSplitPosition(by: step)
                }
                return .handled
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("develop.splitCompare.handle")
            .accessibilityValue(Text(position, format: .percent))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    updateSplitPosition(by: splitStep)
                case .decrement:
                    updateSplitPosition(by: -splitStep)
                @unknown default:
                    break
                }
            }
        }
    }

    /// ドラッグ位置を画像矩形内の分割比率へ変換する純粋な境界処理。
    static func clampedSplitPosition(locationX: CGFloat, in imageFrame: CGRect) -> CGFloat {
        guard imageFrame.width > 0 else { return 0.5 }
        return clamped((locationX - imageFrame.minX) / imageFrame.width)
    }

    /// 分割比率を 0...1 の範囲へ収める。
    static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func fittedImage(_ image: NSImage, in frame: CGRect) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: frame.width, height: frame.height)
    }

    private func imageLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
    }

    private func updateSplitPosition(by amount: CGFloat) {
        splitPosition = Self.clamped(splitPosition + amount)
    }
}
