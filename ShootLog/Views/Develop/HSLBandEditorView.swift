import SwiftUI

/// カラー別 HSL 調整。8 帯域から 1 つ選び、色相 / 彩度 / 輝度を動かす。
struct HSLBandEditorView: View {
    @Binding var hue: [Double]
    @Binding var saturation: [Double]
    @Binding var luminance: [Double]

    @State private var selected: HSLBand = .red

    private var index: Int {
        HSLBand.allCases.firstIndex(of: selected) ?? 0
    }

    private func binding(_ array: Binding<[Double]>) -> Binding<Double> {
        Binding(
            get: { array.wrappedValue.indices.contains(index) ? array.wrappedValue[index] : 0 },
            set: { newValue in
                guard array.wrappedValue.indices.contains(index) else { return }
                array.wrappedValue[index] = newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.xSmall) {
                ForEach(HSLBand.allCases, id: \.self) { band in
                    Button {
                        selected = band
                    } label: {
                        BandSwatch(color: swatchColor(band), isSelected: band == selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(bandLabel(band))
                    .accessibilityAddTraits(band == selected ? .isSelected : [])
                }
            }

            AdjustmentSlider(label: "develop.hsl.hue", value: binding($hue))
            AdjustmentSlider(label: "develop.hsl.saturation", value: binding($saturation))
            AdjustmentSlider(label: "develop.hsl.luminance", value: binding($luminance))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("develop.section.hsl")
    }

    private func swatchColor(_ band: HSLBand) -> Color {
        Color(hue: band.centerHue / 360, saturation: 0.75, brightness: 0.9)
    }

    private struct BandSwatch: View {
        let color: Color
        let isSelected: Bool

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle().strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.5),
                        lineWidth: isSelected ? 2 : 0.5
                    )
                }
        }
    }

    private func bandLabel(_ band: HSLBand) -> LocalizedStringKey {
        switch band {
        case .red: "develop.hsl.band.red"
        case .orange: "develop.hsl.band.orange"
        case .yellow: "develop.hsl.band.yellow"
        case .green: "develop.hsl.band.green"
        case .aqua: "develop.hsl.band.aqua"
        case .blue: "develop.hsl.band.blue"
        case .purple: "develop.hsl.band.purple"
        case .magenta: "develop.hsl.band.magenta"
        }
    }
}
