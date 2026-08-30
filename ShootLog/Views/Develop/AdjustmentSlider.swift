import SwiftUI

/// 現像パネルの調整スライダー 1 行。ラベル + 現在値 + スライダー。
/// 値ラベルをクリックすると中立値へ戻す。
struct AdjustmentSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var neutral: Double = 0
    var fractionDigits: Int = 0
    /// ドラッグ開始で `true`、終了で `false`。RAW の露出・WB の 2 段階描画に使う。
    var onEditingChanged: (Bool) -> Void = { _ in }

    private var isModified: Bool { abs(value - neutral) > 0.0001 }

    private var formattedValue: String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)))
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
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(formattedValue)
        .accessibilityHint("develop.slider.resetValue.help")
    }
}
