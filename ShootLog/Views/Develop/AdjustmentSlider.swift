import SwiftUI

/// 現像パネルの調整スライダー 1 行。ラベル + 現在値 + スライダー。
/// 値ラベルをクリックすると中立値へ戻す。
///
/// 入力・キーボード操作・アクセシビリティはネイティブの `Slider` のまま保ち、
/// 中立値からの振れ幅を示すバイポーラなトラックだけを背面に描く
/// （`WhiteBalanceSection.GradientSlider` と同じ重ね方）。
struct AdjustmentSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var neutral: Double = 0
    var fractionDigits: Int = 0
    /// ドラッグ開始で `true`、終了で `false`。RAW の露出・WB の 2 段階描画に使う。
    var onEditingChanged: (Bool) -> Void = { _ in }

    private static let trackHeight: CGFloat = 4

    private var isModified: Bool { abs(value - neutral) > 0.0001 }

    private var formattedValue: String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    /// トラック上でアクセントを塗る区間。中立値が範囲の中央なら中央から、
    /// 0...100 のような片側レンジなら左端から伸びる。
    private var fillFractions: (start: CGFloat, end: CGFloat) {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return (0, 0) }
        let neutralFraction = fraction(of: neutral, span: span)
        let valueFraction = fraction(of: value, span: span)
        return (min(neutralFraction, valueFraction), max(neutralFraction, valueFraction))
    }

    private func fraction(of raw: Double, span: Double) -> CGFloat {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / span)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Spacing.small)
                Button {
                    value = neutral
                } label: {
                    Text(formattedValue)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isModified ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isModified)
                .help("develop.slider.resetValue.help")
            }
            ZStack {
                track
                Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                    .controlSize(.small)
                    // ネイティブ Slider 自身のトラック塗り（最小値から現在値までを塗る）を消す。
                    // 中立値からの振れ幅を示す `track` と二重表示になり、特にマイナス側では
                    // 「値を戻しても青い帯が広がったまま」に見えていた（実機報告）。
                    .tint(.clear)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(formattedValue)
        .accessibilityHint("develop.slider.resetValue.help")
    }

    private var track: some View {
        GeometryReader { proxy in
            let fractions = fillFractions
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, (fractions.end - fractions.start) * width), height: Self.trackHeight)
                    .offset(x: fractions.start * width)
            }
            .frame(width: width, height: proxy.size.height, alignment: .center)
        }
        .frame(height: Self.trackHeight)
        .accessibilityHidden(true)
    }
}
