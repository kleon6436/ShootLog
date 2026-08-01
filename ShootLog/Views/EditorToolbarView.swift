import SwiftUI

// 中央ビューアに重ねる編集ツールバー（回転・トリミング・リセット）
struct EditorToolbarView: View {
    let editInfo: EditInfo?
    let isCropMode: Bool
    let onRotate: () -> Void
    let onToggleCrop: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            EditorButton(symbolName: "rotate.right", help: "右に 90° 回転", action: onRotate)
            EditorButton(symbolName: "crop", help: "トリミング", isActive: isCropMode, action: onToggleCrop)

            if editInfo != nil {
                Divider().frame(height: 16).padding(.horizontal, 2)
                EditorButton(symbolName: "arrow.uturn.backward", help: "編集をリセット", action: onReset)
            }
        }
        // 内側余白: ボタンとガラスカード端との間隔
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .glassOrMaterial(cornerRadius: CornerRadius.medium)
        // 外側余白: ガラスカードと写真キャンバス端との距離
        .padding(Spacing.large)
    }
}

private struct EditorButton: View {
    let symbolName: String
    let help: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(EditorButtonStyle(isActive: isActive))
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Editor Button Style

private struct EditorButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isActive {
            return Color.accentColor.opacity(isPressed ? 0.25 : 0.15)
        }
        return isPressed ? Color.primary.opacity(0.1) : Color.clear
    }
}
