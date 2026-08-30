import SwiftUI

struct WhiteBalanceSection: View {
    @Bindable var developViewModel: DevelopViewModel

    private var modeBinding: Binding<WhiteBalanceSettings.Mode> {
        Binding(
            get: { developViewModel.parameters.whiteBalance.mode },
            set: { developViewModel.selectWhiteBalanceMode($0) }
        )
    }

    private var temperatureValue: Binding<Double> {
        Binding(
            get: {
                developViewModel.parameters.whiteBalance.mode == .asShot
                    ? (developViewModel.asShotTemperatureKelvin ?? 6_500)
                    : developViewModel.parameters.whiteBalance.temperatureKelvin
            },
            set: { developViewModel.setWhiteBalanceTemperature($0) }
        )
    }

    private var temperatureRange: ClosedRange<Double> {
        guard developViewModel.isAsShotWhiteBalanceLoaded, !developViewModel.isRAW else {
            return WhiteBalanceSettings.minimumTemperature...WhiteBalanceSettings.maximumTemperature
        }

        let asShotTemperature = developViewModel.asShotTemperatureKelvin ?? 6_500
        let current = temperatureValue.wrappedValue
        let lowerBound = min(
            max(WhiteBalanceSettings.minimumTemperature, asShotTemperature - 3_000), current
        )
        let upperBound = max(
            min(WhiteBalanceSettings.maximumTemperature, asShotTemperature + 3_000), current
        )

        guard lowerBound < upperBound else {
            return WhiteBalanceSettings.minimumTemperature...WhiteBalanceSettings.maximumTemperature
        }

        return lowerBound...upperBound
    }

    var body: some View {
        DevelopSectionCard(
            "develop.section.whiteBalance",
            reset: (
                isEnabled: developViewModel.parameters.isModified(in: .whiteBalance),
                action: { developViewModel.resetSection(.whiteBalance) }
            )
        ) {
            modePicker
            temperatureSlider
            GradientSlider(
                label: "develop.whiteBalance.tint",
                value: Binding(
                    get: { developViewModel.parameters.whiteBalance.tint },
                    set: { developViewModel.setWhiteBalanceTint($0) }
                ),
                range: -150...150,
                gradient: LinearGradient(
                    colors: [
                        Color(red: 0.4, green: 0.85, blue: 0.5),
                        Color(red: 0.9, green: 0.5, blue: 0.9)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                onEditingChanged: { developViewModel.setRAWParameterDragging($0) }
            )
            .disabled(!developViewModel.isAsShotWhiteBalanceLoaded)
            asShotCaption
            if let message = developViewModel.whiteBalanceStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modePicker: some View {
        Picker("develop.whiteBalance.mode", selection: modeBinding) {
            ForEach(WhiteBalanceSettings.Mode.allCases, id: \.self) { mode in
                Text(mode.titleKey).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .disabled(!developViewModel.isAsShotWhiteBalanceLoaded)
    }

    private var temperatureSlider: some View {
        GradientSlider(
            label: "develop.whiteBalance.temperature",
            value: temperatureValue,
            range: temperatureRange,
            gradient: LinearGradient(
                colors: [
                    Color(red: 0.45, green: 0.62, blue: 1.0),
                    Color(red: 1.0, green: 0.85, blue: 0.5)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            onEditingChanged: developViewModel.setRAWParameterDragging,
            valueField: true
        )
        .disabled(!developViewModel.isAsShotWhiteBalanceLoaded)
    }

    @ViewBuilder
    private var asShotCaption: some View {
        if let temperature = developViewModel.asShotTemperatureKelvin {
            HStack(spacing: Spacing.small) {
                Text(String(format: String(localized: "develop.whiteBalance.asShotValue"), Int64(temperature)))
                if developViewModel.asShotWhiteBalanceIsEstimated {
                    Text("develop.whiteBalance.estimated")
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private struct GradientSlider: View {
        let label: LocalizedStringKey
        @Binding var value: Double
        let range: ClosedRange<Double>
        let gradient: LinearGradient
        let valueField: Bool
        let onEditingChanged: (Bool) -> Void

        init(
            label: LocalizedStringKey,
            value: Binding<Double>,
            range: ClosedRange<Double>,
            gradient: LinearGradient,
            onEditingChanged: @escaping (Bool) -> Void,
            valueField: Bool = false
        ) {
            self.label = label
            _value = value
            self.range = range
            self.gradient = gradient
            self.valueField = valueField
            self.onEditingChanged = onEditingChanged
        }

        private var formattedValue: String {
            value.formatted(.number.precision(.fractionLength(0)))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.small)
                    if valueField {
                        TextField(
                            label,
                            value: $value,
                            format: .number.precision(.fractionLength(0))
                        )
                        .frame(width: 64)
                        Text("K")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(formattedValue)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ZStack {
                    gradient
                        .frame(height: 4)
                        .clipShape(Capsule())
                    Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: valueField ? .contain : .combine)
            .accessibilityLabel(label)
            .accessibilityValue(formattedValue)
        }
    }
}

private extension WhiteBalanceSettings.Mode {
    var titleKey: LocalizedStringKey {
        switch self {
        case .asShot: "develop.whiteBalance.mode.asShot"
        case .auto: "develop.whiteBalance.mode.auto"
        case .daylight: "develop.whiteBalance.mode.daylight"
        case .cloudy: "develop.whiteBalance.mode.cloudy"
        case .shade: "develop.whiteBalance.mode.shade"
        case .tungsten: "develop.whiteBalance.mode.tungsten"
        case .fluorescent: "develop.whiteBalance.mode.fluorescent"
        case .flash: "develop.whiteBalance.mode.flash"
        case .custom: "develop.whiteBalance.mode.custom"
        }
    }
}

struct ColorGradingEditorView: View {
    @Binding var settings: ColorBalanceSettings
    let reset: (isEnabled: Bool, action: () -> Void)

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.medium),
        GridItem(.flexible())
    ]

    var body: some View {
        DevelopSectionCard("develop.section.colorGrading", reset: reset) {
            LazyVGrid(columns: columns, spacing: Spacing.medium) {
                ColorWheelView(component: $settings.master, title: "develop.colorGrading.master")
                ColorWheelView(component: $settings.shadows, title: "develop.colorGrading.shadows")
                ColorWheelView(component: $settings.midtones, title: "develop.colorGrading.midtones")
                ColorWheelView(component: $settings.highlights, title: "develop.colorGrading.highlights")
            }
        }
    }
}

/// DevelopPanelViewと同じカード表現を共有する小さな公開コンテナ。
struct DevelopSectionCard<Content: View>: View {
    let title: LocalizedStringKey
    var reset: (isEnabled: Bool, action: () -> Void)?
    @ViewBuilder let content: () -> Content

    init(
        _ title: LocalizedStringKey,
        reset: (isEnabled: Bool, action: () -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.reset = reset
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset {
                    Button(action: reset.action) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(!reset.isEnabled)
                    .help("develop.section.reset.help")
                    .accessibilityLabel("develop.section.reset")
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.medium)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
    }
}
