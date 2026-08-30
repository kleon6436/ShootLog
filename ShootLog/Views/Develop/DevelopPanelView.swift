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

                HistogramView(
                    data: developViewModel.histogram,
                    showsClippingWarnings: developViewModel.showsClippingWarnings
                )

                Toggle("develop.clipping.showWarnings", isOn: $developViewModel.showsClippingWarnings)
                    .toggleStyle(.checkbox)

                Button(
                    developViewModel.isShowingBefore ? "develop.beforeAfter.showAfter" : "develop.beforeAfter.showBefore",
                    systemImage: "rectangle.split.2x1"
                ) {
                    developViewModel.toggleBeforeAfter()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .accessibilityLabel("develop.beforeAfter")

                DevelopSectionCard("develop.section.basic", reset: sectionReset(.basic)) {
                    AdjustmentSlider(
                        label: "develop.exposure",
                        value: $developViewModel.parameters.exposure,
                        range: -3...3,
                        fractionDigits: 2,
                        onEditingChanged: { developViewModel.setRAWParameterDragging($0) }
                    )
                    AdjustmentSlider(label: "develop.contrast", value: $developViewModel.parameters.contrast)
                    AdjustmentSlider(label: "develop.highlights", value: $developViewModel.parameters.highlights)
                    AdjustmentSlider(label: "develop.shadows", value: $developViewModel.parameters.shadows)
                    AdjustmentSlider(label: "develop.whites", value: $developViewModel.parameters.whites)
                    AdjustmentSlider(label: "develop.blacks", value: $developViewModel.parameters.blacks)
                    AdjustmentSlider(label: "develop.brightness", value: $developViewModel.parameters.brightness)
                }

                WhiteBalanceSection(developViewModel: developViewModel)

                DevelopSectionCard("develop.section.color", reset: sectionReset(.color)) {
                    AdjustmentSlider(label: "develop.vibrance", value: $developViewModel.parameters.vibrance)
                    AdjustmentSlider(label: "develop.saturation", value: $developViewModel.parameters.saturation)
                }

                DevelopSectionCard("develop.section.toneCurve", reset: sectionReset(.toneCurve)) {
                    ToneCurveEditorView(
                        rgb: $developViewModel.parameters.toneCurveRGB,
                        red: $developViewModel.parameters.toneCurveRed,
                        green: $developViewModel.parameters.toneCurveGreen,
                        blue: $developViewModel.parameters.toneCurveBlue
                    )
                }

                DevelopSectionCard("develop.section.hsl", reset: sectionReset(.hsl)) {
                    HSLBandEditorView(
                        hue: $developViewModel.parameters.hslHue,
                        saturation: $developViewModel.parameters.hslSaturation,
                        luminance: $developViewModel.parameters.hslLuminance
                    )
                }

                DevelopSectionCard("develop.section.detail", reset: sectionReset(.detail)) {
                    AdjustmentSlider(label: "develop.clarity", value: $developViewModel.parameters.clarity)
                    AdjustmentSlider(label: "develop.structure", value: $developViewModel.parameters.structure)
                    AdjustmentSlider(label: "develop.dehaze", value: $developViewModel.parameters.dehaze)
                    AdjustmentSlider(label: "develop.vignette", value: $developViewModel.parameters.vignette)
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

                ColorGradingEditorView(
                    settings: $developViewModel.parameters.colorBalance,
                    reset: sectionReset(.colorGrading)
                )

                DevelopSectionCard("develop.section.blackAndWhite", reset: sectionReset(.blackAndWhite)) {
                    Toggle("develop.blackAndWhite.enabled", isOn: $developViewModel.parameters.blackAndWhiteEnabled)
                    let bandKeys = [
                        "develop.hsl.band.red", "develop.hsl.band.orange", "develop.hsl.band.yellow",
                        "develop.hsl.band.green", "develop.hsl.band.aqua", "develop.hsl.band.blue"
                    ]
                    ForEach(0..<6, id: \.self) { index in
                        AdjustmentSlider(
                            label: LocalizedStringKey(bandKeys[index]),
                            value: Binding(
                                get: { developViewModel.parameters.bwMix.indices.contains(index) ? developViewModel.parameters.bwMix[index] : 0 },
                                set: { value in
                                    guard developViewModel.parameters.bwMix.indices.contains(index) else { return }
                                    developViewModel.parameters.bwMix[index] = value
                                }
                            )
                        )
                    }
                }

                if developViewModel.canDelegateToRAWFilter || developViewModel.canEditManualLensCorrection {
                    DevelopSectionCard("develop.section.lens", reset: sectionReset(.lens)) {
                        if developViewModel.canDelegateToRAWFilter {
                            Toggle(
                                "develop.lens.correction",
                                isOn: $developViewModel.parameters.lensCorrectionEnabled
                            )
                            .accessibilityLabel("develop.lens.correction")
                        }

                        if developViewModel.canEditManualLensCorrection {
                            AdjustmentSlider(
                                label: "develop.lens.distortion",
                                value: $developViewModel.parameters.lensDistortion
                            )
                            AdjustmentSlider(
                                label: "develop.lens.vignette",
                                value: $developViewModel.parameters.lensVignette
                            )
                            AdjustmentSlider(
                                label: "develop.lens.chromaticAberration",
                                value: $developViewModel.parameters.lensChromaticAberration
                            )
                        } else if developViewModel.canDelegateToRAWFilter
                            && developViewModel.parameters.lensCorrectionEnabled {
                            Text("develop.lens.handledByRAWFilter")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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

    private func sectionReset(_ section: DevelopSection) -> (isEnabled: Bool, action: () -> Void) {
        (
            isEnabled: developViewModel.parameters.isModified(in: section),
            action: { developViewModel.resetSection(section) }
        )
    }
}
