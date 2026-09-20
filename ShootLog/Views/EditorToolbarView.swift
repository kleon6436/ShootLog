import SwiftUI

// 中央ビューアの下端中央に浮かべる編集ツールバー（現像・回転・トリミング・お気に入り・超解像・リセット）。
// ツールバーやHUDと同じ「機能層のフローティングコントロール」なので、macOS 26 以降は
// GlassEffectContainer + カプセル型のリキッドグラス、それ以前は regularMaterial のカプセルで描く。
// コンテンツ層のカード（.contentCard）とは別系統であることに注意する
struct EditorToolbarView: View {
    let editInfo: EditInfo?
    let isCropMode: Bool
    let isFavorite: Bool
    let isDevelopActive: Bool
    let isPhotosLibraryPhoto: Bool
    let onRotate: () -> Void
    let onToggleCrop: () -> Void
    let onToggleFavorite: () -> Void
    let onEditDevelop: () -> Void
    let onReset: () -> Void
    let onUpscale: () -> Void

    // カプセル下端と写真キャンバス下端との距離
    private static let bottomInset: CGFloat = 20

    var body: some View {
        glassCapsule
            .padding(.bottom, Self.bottomInset)
    }

    // macOS 26 以降は複数のガラス要素を1つの容器にまとめて合成コストと見えを揃える。
    // 中身は同一なので、分岐するのは背景の描き方だけに留める
    @ViewBuilder
    private var glassCapsule: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer {
                buttonRow.glassEffect(in: Capsule())
            }
        } else {
            buttonRow.background(.regularMaterial, in: Capsule())
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 2) {
            EditorButton(
                symbolName: "slider.horizontal.3",
                help: "editor.develop",
                isActive: isDevelopActive,
                action: onEditDevelop
            )
            .disabled(isPhotosLibraryPhoto)
            EditorButton(symbolName: "rotate.right", help: "editor.rotate", action: onRotate)
            EditorButton(symbolName: "crop", help: "editor.crop", isActive: isCropMode, action: onToggleCrop)
            EditorButton(
                symbolName: isFavorite ? "star.fill" : "star",
                help: isFavorite ? "viewer.favorite.remove" : "viewer.favorite.add",
                isActive: isFavorite,
                // お気に入りだけは塗り潰さず記号の色で示す（写真.app・Finderのタグと同じ黄色の意味付け）
                accent: .symbol(.yellow),
                action: onToggleFavorite
            )
            EditorButton(symbolName: "wand.and.sparkles", help: "editor.upscale", action: onUpscale)
                .disabled(isPhotosLibraryPhoto)

            if editInfo != nil {
                Divider().frame(height: 16).padding(.horizontal, 2)
                EditorButton(symbolName: "arrow.uturn.backward", help: "editor.reset", action: onReset)
            }
        }
        // 内側余白: ボタン列とカプセル端との間隔
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.xSmall)
    }
}

// MARK: - Editor Button

// アクティブ状態の見せ方。トグル（現像・トリミング）は面で、
// お気に入りは記号の色だけで示して意味の違いを視覚的にも分ける
private enum EditorButtonAccent {
    // アクセント色のカプセルで塗り潰し、記号を白にする
    case filled
    // 記号の色だけを変える
    case symbol(Color)
}

private struct EditorButton: View {
    let symbolName: String
    let help: LocalizedStringKey
    var isActive: Bool = false
    var accent: EditorButtonAccent = .filled
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 16))
        }
        .buttonStyle(EditorButtonStyle(isActive: isActive, accent: accent))
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Editor Button Style

private struct EditorButtonStyle: ButtonStyle {
    let isActive: Bool
    let accent: EditorButtonAccent

    func makeBody(configuration: Configuration) -> some View {
        // ButtonStyle（値型）は makeBody 内に @State を持てないため、
        // ホバー状態の保持だけを目的に専用の View へ分離する（HUDButtonStyle と同じ構成）
        EditorButtonBody(configuration: configuration, isActive: isActive, accent: accent)
    }
}

private struct EditorButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool
    let accent: EditorButtonAccent
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    // 44pt には満たないが、カプセル内に6個並べても写真を隠さない幅として
    // macOS のツールバーボタン相当のヒット領域を確保する
    private static let hitWidth: CGFloat = 36
    private static let hitHeight: CGFloat = 32

    var body: some View {
        configuration.label
            .foregroundStyle(symbolColor)
            .frame(width: Self.hitWidth, height: Self.hitHeight)
            // background のカプセルは見た目のみでヒットテストに影響しないため明示する
            .contentShape(Capsule())
            .background { backgroundShape }
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }

    // 塗り潰し時のみ、アクセント色の上で最も読みやすい白を置く（.borderedProminent と同じ考え方）
    private var symbolColor: Color {
        guard isActive else { return .primary }
        switch accent {
        case .filled:
            return Color.onAccent
        case .symbol(let color):
            return color
        }
    }

    @ViewBuilder
    private var backgroundShape: some View {
        if isActive, case .filled = accent {
            Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
        } else if configuration.isPressed {
            Capsule().fill(Color.primary.opacity(0.16))
        } else if isHovered, isEnabled {
            Capsule().fill(Color.primary.opacity(0.08))
        }
    }
}
