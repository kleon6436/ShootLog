import SwiftUI

/// 現像パネルの「マスク」セクション。Phase 1a では線形グラデーションマスクだけを扱う。
///
/// 編集はすべて `DevelopViewModel.updateMask(id:_:)` 経由で行う。`parameters` へ代入し直す
/// ことで VM 側の didSet が再描画と永続化を予約する契約のため、`MaskLayer` を直接束縛しない。
struct MaskSectionView: View {
    @Bindable var developViewModel: DevelopViewModel

    var body: some View {
        DevelopSectionCard("develop.section.masks") {
            addButton

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

    private var addButton: some View {
        Button("develop.mask.addLinearGradient", systemImage: "circle.lefthalf.striped.horizontal") {
            developViewModel.addLinearGradientMask()
        }
        .disabled(!developViewModel.canEditMasks)
    }

    private var layerList: some View {
        VStack(spacing: 2) {
            ForEach(developViewModel.maskLayers) { layer in
                layerRow(layer)
            }
        }
    }

    private func layerRow(_ layer: MaskLayer) -> some View {
        let isSelected = developViewModel.selectedMaskLayerID == layer.id
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
                Text(layer.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(layer.name))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

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
    private func selectedLayerEditor(id: UUID) -> some View {
        Toggle("develop.mask.invert", isOn: binding(id, \.isInverted, default: false))
            .toggleStyle(.checkbox)

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
        AdjustmentSlider(
            label: "develop.whiteBalance.temperature",
            value: binding(id, \.adjustments.temperature, default: 0)
        )
        AdjustmentSlider(
            label: "develop.whiteBalance.tint",
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
}
