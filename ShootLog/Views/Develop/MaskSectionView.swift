import SwiftUI

/// 現像パネルの「マスク」セクション。Phase 1a では線形グラデーションマスクだけを扱う。
///
/// 編集はすべて `DevelopViewModel.updateMask(id:_:)` 経由で行う。`parameters` へ代入し直す
/// ことで VM 側の didSet が再描画と永続化を予約する契約のため、`MaskLayer` を直接束縛しない。
struct MaskSectionView: View {
    @Bindable var developViewModel: DevelopViewModel

    var body: some View {
        DevelopSectionCard("develop.section.masks") {
            addButtons

            if !developViewModel.canEditMasks {
                Text("develop.mask.unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !developViewModel.maskLayers.isEmpty {
                layerList

                Toggle("develop.mask.showOverlay", isOn: $developViewModel.maskEditMode)
                    .toggleStyle(.checkbox)
                    .disabled(!developViewModel.canEditMasks)
            }

            if let id = selectedLayerID {
                Divider()
                selectedLayerEditor(id: id)
            }
        }
    }

    /// 選択中レイヤーの ID。削除直後など実体が無い ID は無効として扱う。
    private var selectedLayerID: UUID? {
        guard let id = developViewModel.selectedMaskLayerID,
              developViewModel.maskLayers.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private var addButtons: some View {
        HStack(spacing: Spacing.small) {
            Button("develop.mask.addLinearGradient", systemImage: "circle.lefthalf.striped.horizontal") {
                developViewModel.addLinearGradientMask()
            }
            Button("develop.mask.addRadialGradient", systemImage: "circle.circle") {
                developViewModel.addRadialGradientMask()
            }
        }
        .disabled(!developViewModel.canEditMasks)
    }

    private var layerList: some View {
        VStack(spacing: 2) {
            ForEach(Array(developViewModel.maskLayers.enumerated()), id: \.element.id) { index, layer in
                layerRow(layer, index: index)
            }
        }
    }

    private func layerRow(_ layer: MaskLayer, index: Int) -> some View {
        let isSelected = developViewModel.selectedMaskLayerID == layer.id
        let isUnsupported: Bool = if case .unrecognized = layer.source { true } else { false }
        // トグル・選択・削除の3操作をそれぞれVoiceOverから独立に到達可能にするため、
        // 3要素を1つに畳み込む .combine ではなく .contain を使う（ai-category-inspector-display
        // で .combine がインタラクティブな子要素のアクションを潰した既知の失敗パターンを踏まない）。
        return HStack(spacing: Spacing.small) {
            Toggle("develop.mask.enabled", isOn: binding(layer.id, \.isEnabled, default: true))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text("develop.mask.enabled"))

            Button {
                developViewModel.selectedMaskLayerID = layer.id
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(layer.name)
                        .font(.caption)
                        .lineLimit(1)
                    if isUnsupported {
                        Text("develop.mask.unsupported")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(layer.name))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            moveButtons(index: index)

            Button(role: .destructive) {
                developViewModel.removeMask(id: layer.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("develop.mask.delete")
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, 3)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: CornerRadius.small)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func moveButtons(index: Int) -> some View {
        Button {
            developViewModel.moveMasks(from: IndexSet(integer: index), to: index - 1)
        } label: {
            Image(systemName: "chevron.up")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .disabled(index == 0)
        .accessibilityLabel("a11y.mask.moveUp")

        Button {
            developViewModel.moveMasks(from: IndexSet(integer: index), to: index + 2)
        } label: {
            Image(systemName: "chevron.down")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .disabled(index == developViewModel.maskLayers.count - 1)
        .accessibilityLabel("a11y.mask.moveDown")
    }

    @ViewBuilder
    private func selectedLayerEditor(id: UUID) -> some View {
        TextField("develop.mask.name", text: binding(id, \.name, default: ""))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("develop.mask.name")

        Toggle("develop.mask.invert", isOn: binding(id, \.isInverted, default: false))
            .toggleStyle(.checkbox)

        radialGradientSliders(id: id)

        AdjustmentSlider(
            label: "develop.mask.density",
            value: binding(id, \.density, default: 100),
            range: 0...100,
            neutral: 100
        )
        AdjustmentSlider(
            label: "develop.mask.feather",
            value: binding(id, \.feather, default: 0),
            range: 0...100
        )

        localAdjustmentSliders(id: id)
    }

    /// 放射状グラデーション専用のスライダー。中心・半径・回転はビューア上のハンドルで操作する。
    @ViewBuilder
    private func radialGradientSliders(id: UUID) -> some View {
        if let layer = developViewModel.maskLayers.first(where: { $0.id == id }),
           case .radialGradient = layer.source {
            AdjustmentSlider(
                label: "develop.mask.aspectRatio",
                value: radialBinding(id, \.aspectRatio, default: 1),
                range: 0.2...5,
                neutral: 1,
                fractionDigits: 2
            )
            AdjustmentSlider(
                label: "develop.mask.falloff",
                value: radialBinding(id, \.falloff, default: 50),
                range: 0...100,
                neutral: 50
            )
        }
    }

    @ViewBuilder
    private func localAdjustmentSliders(id: UUID) -> some View {
        AdjustmentSlider(
            label: "develop.exposure",
            value: binding(id, \.adjustments.exposure, default: 0),
            range: -3...3,
            fractionDigits: 2
        )
        AdjustmentSlider(label: "develop.contrast", value: binding(id, \.adjustments.contrast, default: 0))
        AdjustmentSlider(label: "develop.highlights", value: binding(id, \.adjustments.highlights, default: 0))
        AdjustmentSlider(label: "develop.shadows", value: binding(id, \.adjustments.shadows, default: 0))
        AdjustmentSlider(label: "develop.whites", value: binding(id, \.adjustments.whites, default: 0))
        AdjustmentSlider(label: "develop.blacks", value: binding(id, \.adjustments.blacks, default: 0))
        AdjustmentSlider(label: "develop.vibrance", value: binding(id, \.adjustments.vibrance, default: 0))
        AdjustmentSlider(label: "develop.saturation", value: binding(id, \.adjustments.saturation, default: 0))
        AdjustmentSlider(label: "develop.clarity", value: binding(id, \.adjustments.clarity, default: 0))
        AdjustmentSlider(label: "develop.structure", value: binding(id, \.adjustments.structure, default: 0))
        AdjustmentSlider(
            label: "develop.sharpness",
            value: binding(id, \.adjustments.sharpness, default: 0),
            range: 0...100
        )
        AdjustmentSlider(
            label: "develop.noiseReduction.luminance",
            value: binding(id, \.adjustments.luminanceNoiseReduction, default: 0),
            range: 0...100
        )
        AdjustmentSlider(
            label: "develop.noiseReduction.color",
            value: binding(id, \.adjustments.colorNoiseReduction, default: 0),
            range: 0...100
        )
        // 局所段の WB は相対オフセットで、絶対 Kelvin のグローバル WB とは意味論が異なるため
        // ラベルを分ける（実装プラン §3.1.1）。
        AdjustmentSlider(
            label: "develop.mask.temperature",
            value: binding(id, \.adjustments.temperature, default: 0)
        )
        AdjustmentSlider(
            label: "develop.mask.tint",
            value: binding(id, \.adjustments.tint, default: 0)
        )
    }

    /// ID で引いたレイヤーの 1 フィールドを `updateMask` 経由で読み書きする束縛。
    private func binding<Value>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<MaskLayer, Value>,
        default defaultValue: Value
    ) -> Binding<Value> {
        Binding(
            get: { developViewModel.maskLayers.first { $0.id == id }?[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                developViewModel.updateMask(id: id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    /// 放射状グラデーションのペイロード 1 フィールドを読み書きする束縛。
    /// `MaskSource` が enum なので `binding(_:_:default:)` の KeyPath では届かない。
    private func radialBinding(
        _ id: UUID,
        _ keyPath: WritableKeyPath<RadialGradientMask, Double>,
        default defaultValue: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                guard let layer = developViewModel.maskLayers.first(where: { $0.id == id }),
                      case .radialGradient(let mask) = layer.source else { return defaultValue }
                return mask[keyPath: keyPath]
            },
            set: { newValue in
                developViewModel.updateMask(id: id) { layer in
                    guard case .radialGradient(var mask) = layer.source else { return }
                    mask[keyPath: keyPath] = newValue
                    layer.source = .radialGradient(mask)
                }
            }
        )
    }
}
