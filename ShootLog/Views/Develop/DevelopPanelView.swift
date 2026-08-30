import SwiftUI

/// 右インスペクタの「編集」タブ。現像調整のセクション群。
/// スライダーは `developViewModel.parameters` を直接書き換え、VM 側でプレビュー再描画と保存を予約する。
struct DevelopPanelView: View {
    @Bindable var developViewModel: DevelopViewModel
    var onExport: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                DevelopPresetBar(developViewModel: developViewModel)

                HistogramView(data: developViewModel.histogram)

                DevelopSection("develop.section.basic") {
                    AdjustmentSlider(
                        label: "develop.exposure",
                        value: $developViewModel.parameters.exposure,
                        range: -3...3,
                        fractionDigits: 2
                    )
                    AdjustmentSlider(label: "develop.contrast", value: $developViewModel.parameters.contrast)
                    AdjustmentSlider(label: "develop.highlights", value: $developViewModel.parameters.highlights)
                    AdjustmentSlider(label: "develop.shadows", value: $developViewModel.parameters.shadows)
                    AdjustmentSlider(label: "develop.whites", value: $developViewModel.parameters.whites)
                    AdjustmentSlider(label: "develop.blacks", value: $developViewModel.parameters.blacks)
                    AdjustmentSlider(label: "develop.brightness", value: $developViewModel.parameters.brightness)
                }

                DevelopSection("develop.section.color") {
                    AdjustmentSlider(label: "develop.temperature", value: $developViewModel.parameters.temperature)
                    AdjustmentSlider(label: "develop.tint", value: $developViewModel.parameters.tint)
                    AdjustmentSlider(label: "develop.vibrance", value: $developViewModel.parameters.vibrance)
                    AdjustmentSlider(label: "develop.saturation", value: $developViewModel.parameters.saturation)
                }

                DevelopSection("develop.section.toneCurve") {
                    ToneCurveEditorView(
                        rgb: $developViewModel.parameters.toneCurveRGB,
                        red: $developViewModel.parameters.toneCurveRed,
                        green: $developViewModel.parameters.toneCurveGreen,
                        blue: $developViewModel.parameters.toneCurveBlue
                    )
                }

                DevelopSection("develop.section.hsl") {
                    HSLBandEditorView(
                        hue: $developViewModel.parameters.hslHue,
                        saturation: $developViewModel.parameters.hslSaturation,
                        luminance: $developViewModel.parameters.hslLuminance
                    )
                }

                DevelopSection("develop.section.detail") {
                    AdjustmentSlider(
                        label: "develop.sharpness",
                        value: $developViewModel.parameters.sharpness,
                        range: 0...100
                    )
                    AdjustmentSlider(
                        label: "develop.noiseReduction.luminance",
                        value: $developViewModel.parameters.luminanceNoiseReduction,
                        range: 0...100
                    )
                    AdjustmentSlider(
                        label: "develop.noiseReduction.color",
                        value: $developViewModel.parameters.colorNoiseReduction,
                        range: 0...100
                    )
                }

                HStack {
                    Button("develop.reset", role: .destructive) {
                        developViewModel.reset()
                    }
                    .disabled(!developViewModel.canReset)

                    Spacer()

                    Button("develop.export", systemImage: "square.and.arrow.up") {
                        onExport()
                    }
                }
            }
            .padding(Spacing.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// パネル内のセクションカード。EXIF パネルの `EXIFCard` と視覚言語を揃える。
private struct DevelopSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.medium)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
    }
}
