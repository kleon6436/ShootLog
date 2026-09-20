import SwiftUI

/// 右インスペクタの「編集」タブ。現像調整のセクション群。
/// スライダーは `developViewModel.parameters` を直接書き換え、VM 側でプレビュー再描画と保存を予約する。
struct DevelopPanelView: View {
    @Bindable var developViewModel: DevelopViewModel
    var onExport: () -> Void = {}

    @State private var isResetConfirmationPresented = false

    /// ビューアの表示モード。`isShowingBefore` / `isComparingSplit` は VM 側で排他になっているため、
    /// セグメントの選択はその 2 つの Bool への写像として扱う。
    private enum CompareMode: Hashable {
        case normal
        case before
        case split
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    DevelopPresetBar(developViewModel: developViewModel)

                    HistogramView(
                        data: developViewModel.histogram,
                        showsClippingWarnings: developViewModel.showsClippingWarnings
                    )

                    compareRow

                    sections
                }
                .padding(.horizontal, Spacing.xLarge)
                .padding(.vertical, Spacing.large)
            }

            Divider()

            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - セクション群

    @ViewBuilder
    private var sections: some View {
        DevelopSectionCard(
            "develop.section.basic",
            id: "basic",
            defaultExpanded: true,
            reset: sectionReset(.basic)
        ) {
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

        DevelopSectionCard(
            "develop.section.color",
            id: "color",
            summary: colorSummary,
            reset: sectionReset(.color)
        ) {
            AdjustmentSlider(label: "develop.vibrance", value: $developViewModel.parameters.vibrance)
            AdjustmentSlider(label: "develop.saturation", value: $developViewModel.parameters.saturation)
        }

        DevelopSectionCard("develop.section.toneCurve", id: "toneCurve", reset: sectionReset(.toneCurve)) {
            ToneCurveEditorView(
                rgb: $developViewModel.parameters.toneCurveRGB,
                red: $developViewModel.parameters.toneCurveRed,
                green: $developViewModel.parameters.toneCurveGreen,
                blue: $developViewModel.parameters.toneCurveBlue
            )
        }

        DevelopSectionCard("develop.section.hsl", id: "hsl", reset: sectionReset(.hsl)) {
            HSLBandEditorView(
                hue: $developViewModel.parameters.hslHue,
                saturation: $developViewModel.parameters.hslSaturation,
                luminance: $developViewModel.parameters.hslLuminance
            )
        }

        DevelopSectionCard(
            "develop.section.detail",
            id: "detail",
            summary: detailSummary,
            reset: sectionReset(.detail)
        ) {
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

        DevelopSectionCard(
            "develop.section.blackAndWhite",
            id: "blackAndWhite",
            reset: sectionReset(.blackAndWhite)
        ) {
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

        MaskSectionView(developViewModel: developViewModel)

        if developViewModel.canDelegateToRAWFilter || developViewModel.canEditManualLensCorrection {
            DevelopSectionCard(
                "develop.section.lens",
                id: "lens",
                summary: lensSummary,
                reset: sectionReset(.lens)
            ) {
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
    }

    // MARK: - 比較表示・クリッピング警告

    private var compareRow: some View {
        HStack(spacing: Spacing.small) {
            Picker("a11y.develop.compareMode", selection: compareModeBinding) {
                Text("develop.compare.normal").tag(CompareMode.normal)
                Text("develop.compare.before").tag(CompareMode.before)
                Text("develop.compare.split").tag(CompareMode.split)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("a11y.develop.compareMode")

            Toggle(isOn: $developViewModel.showsClippingWarnings) {
                Image(systemName: "exclamationmark.triangle")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("develop.clipping.showWarnings")
            .accessibilityLabel("develop.clipping.showWarnings")
        }
        // セグメントには keyboardShortcut を付けられないため、既存のショートカットは
        // 0 サイズの不可視ボタンで維持する。
        .background(compareShortcuts)
    }

    private var compareShortcuts: some View {
        ZStack {
            Button("develop.beforeAfter") { developViewModel.toggleBeforeAfter() }
                .keyboardShortcut("b", modifiers: [.command, .option])

            Button("develop.splitCompare") { developViewModel.toggleSplitCompare() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(developViewModel.previewImage == nil)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var compareModeBinding: Binding<CompareMode> {
        Binding(
            get: {
                if developViewModel.isShowingBefore {
                    .before
                } else if developViewModel.isComparingSplit {
                    .split
                } else {
                    .normal
                }
            },
            set: { mode in
                switch mode {
                case .normal:
                    developViewModel.isShowingBefore = false
                    developViewModel.isComparingSplit = false
                case .before:
                    // didSet 側で分割比較と排他になる。
                    developViewModel.isShowingBefore = true
                case .split:
                    // プレビュー未生成なら VM の didSet が false へ戻す。
                    developViewModel.isComparingSplit = true
                }
            }
        )
    }

    // MARK: - フッター

    private var footer: some View {
        HStack(spacing: Spacing.medium) {
            Button("develop.reset", role: .destructive) {
                if developViewModel.resetRequiresConfirmation {
                    isResetConfirmationPresented = true
                } else {
                    developViewModel.reset()
                }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!developViewModel.canReset)
            .confirmationDialog(
                "develop.reset.confirmTitle",
                isPresented: $isResetConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("develop.reset.confirmAction", role: .destructive) {
                    developViewModel.reset()
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("develop.reset.confirmMessage")
            }

            Button {
                onExport()
            } label: {
                Label("develop.export", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, Spacing.xLarge)
        .padding(.vertical, Spacing.large)
    }

    // MARK: - 折りたたみ時のサマリー

    /// 折りたたみ時に値を 1 行で示す。ラベルは既存のスライダー用キーを流用する。
    private func summaryItem(_ key: String.LocalizationValue, value: Double) -> String? {
        guard abs(value) > 0.0001 else { return nil }
        return "\(String(localized: key)) \(Int(value.rounded()))"
    }

    private var colorSummary: String? {
        let parts = [
            summaryItem("develop.vibrance", value: developViewModel.parameters.vibrance),
            summaryItem("develop.saturation", value: developViewModel.parameters.saturation)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var detailSummary: String? {
        summaryItem("develop.sharpness", value: developViewModel.parameters.sharpness)
    }

    private var lensSummary: String? {
        guard developViewModel.canDelegateToRAWFilter,
              developViewModel.parameters.lensCorrectionEnabled else { return nil }
        return String(localized: "develop.section.summary.lensProfile")
    }

    private func sectionReset(_ section: DevelopSection) -> (isEnabled: Bool, action: () -> Void) {
        (
            isEnabled: developViewModel.parameters.isModified(in: section),
            action: { developViewModel.resetSection(section) }
        )
    }
}
