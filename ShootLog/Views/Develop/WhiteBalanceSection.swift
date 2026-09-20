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
            id: "whiteBalance",
            defaultExpanded: true,
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
        DevelopSectionCard("develop.section.colorGrading", id: "colorGrading", reset: reset) {
            LazyVGrid(columns: columns, spacing: Spacing.medium) {
                ColorWheelView(component: $settings.master, title: "develop.colorGrading.master")
                ColorWheelView(component: $settings.shadows, title: "develop.colorGrading.shadows")
                ColorWheelView(component: $settings.midtones, title: "develop.colorGrading.midtones")
                ColorWheelView(component: $settings.highlights, title: "develop.colorGrading.highlights")
            }
        }
    }
}

/// 現像パネルのセクションカード。ヘッダー行のクリックで開閉し、状態は `@AppStorage` で永続化する。
///
/// `DisclosureGroup` は macOS でヘッダー行のレイアウト（高さ・シェブロンの位置・右端の
/// リセットボタン）を規定どおりに作れないため、同等の挙動を持つカスタムビューにしている。
struct DevelopSectionCard<Content: View>: View {
    private let title: LocalizedStringKey
    /// 折りたたみ時にだけ出す要約。ローカライズ済みの文字列を渡す。
    private let summary: String?
    private let reset: (isEnabled: Bool, action: () -> Void)?
    private let content: () -> Content

    @AppStorage private var isExpanded: Bool

    init(
        _ title: LocalizedStringKey,
        id: String,
        summary: String? = nil,
        defaultExpanded: Bool = false,
        reset: (isEnabled: Bool, action: () -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.summary = summary
        self.reset = reset
        self.content = content
        _isExpanded = AppStorage(wrappedValue: defaultExpanded, "develop.section.\(id).expanded")
    }

    private var isModified: Bool { reset?.isEnabled ?? false }

    /// 三項演算子で文字列リテラルを渡すと LocalizedStringKey / String の
    /// オーバーロードが曖昧になるため、Text として明示的に組み立てる。
    private var expansionStateValue: Text {
        isExpanded ? Text("a11y.section.expanded") : Text("a11y.section.collapsed")
    }

    /// 折りたたみ時の要約は目視では見えるので、VoiceOver にも展開状態と併せて伝える。
    private var accessibilityValueText: Text {
        if !isExpanded, let summary {
            return expansionStateValue + Text(verbatim: ", ") + Text(summary)
        }
        return expansionStateValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.large)
                .padding(.bottom, Spacing.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(padding: 0)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: Spacing.small) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: Spacing.small) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: Spacing.small)
                    if !isExpanded, let summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if isModified {
                        // 色だけに頼らないよう、折りたたみ時は summary と併用する。
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValueText)

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
        .frame(height: 30)
        .padding(.horizontal, Spacing.large)
    }
}
