import SwiftUI

struct WhiteBalanceSection: View {
    @Bindable var developViewModel: DevelopViewModel

    private var modeBinding: Binding<WhiteBalanceSettings.Mode> {
        Binding(
            get: { developViewModel.parameters.whiteBalance.mode },
            set: { developViewModel.selectWhiteBalanceMode($0) }
        )
    }

    var body: some View {
        DevelopSectionCard("develop.section.whiteBalance") {
            Picker("develop.whiteBalance.mode", selection: modeBinding) {
                ForEach(WhiteBalanceSettings.Mode.allCases, id: \.self) { mode in
                    Text("develop.whiteBalance.mode.\(mode.rawValue)").tag(mode)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button("develop.whiteBalance.asShot") { developViewModel.setWhiteBalanceAsShot() }
                Button("develop.whiteBalance.auto") { developViewModel.applyAutomaticWhiteBalance() }
                Button("develop.whiteBalance.picker", systemImage: "eyedropper") {
                    developViewModel.beginWhiteBalancePicking()
                }
                Button("develop.whiteBalance.copy", systemImage: "doc.on.doc") {
                    developViewModel.copyWhiteBalance()
                }
                Button("develop.whiteBalance.paste", systemImage: "doc.on.clipboard") {
                    developViewModel.pasteWhiteBalance()
                }
                .disabled(!developViewModel.canPasteWhiteBalance)
            }
            .buttonStyle(.borderless)

            HStack {
                Text("develop.whiteBalance.kelvin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "develop.whiteBalance.kelvin", value: $developViewModel.parameters.whiteBalance.temperatureKelvin,
                    format: .number.precision(.fractionLength(0))
                )
                .frame(width: 72)
                .onChange(of: developViewModel.parameters.whiteBalance.temperatureKelvin) { _, _ in
                    developViewModel.parameters.whiteBalance.mode = .custom
                    developViewModel.parameters.whiteBalance.normalize()
                }
                Text("K").font(.caption).foregroundStyle(.secondary)
            }
            AdjustmentSlider(
                label: "develop.whiteBalance.tint",
                value: $developViewModel.parameters.whiteBalance.tint,
                range: -150...150,
                onEditingChanged: { developViewModel.setRAWParameterDragging($0) }
            )

            if let message = developViewModel.whiteBalanceStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ColorBalanceEditorView: View {
    @Binding var settings: ColorBalanceSettings

    var body: some View {
        DevelopSectionCard("develop.section.colorBalance") {
            component("develop.colorBalance.master", binding: $settings.master)
            component("develop.colorBalance.shadows", binding: $settings.shadows)
            component("develop.colorBalance.midtones", binding: $settings.midtones)
            component("develop.colorBalance.highlights", binding: $settings.highlights)
        }
    }

    private func component(_ title: LocalizedStringKey, binding: Binding<ColorBalanceComponent>) -> some View {
        DisclosureGroup(title) {
            AdjustmentSlider(label: "develop.colorBalance.hue", value: binding.hue)
            AdjustmentSlider(label: "develop.colorBalance.saturation", value: binding.saturation)
            AdjustmentSlider(label: "develop.colorBalance.lightness", value: binding.lightness)
        }
    }
}

/// DevelopPanelViewと同じカード表現を共有する小さな公開コンテナ。
struct DevelopSectionCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.medium)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
    }
}
