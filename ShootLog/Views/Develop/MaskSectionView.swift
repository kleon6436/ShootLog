import SwiftUI

/// 現像パネルの「マスク」セクション。Phase 1a では線形グラデーションマスクだけを扱う。
///
/// 編集はすべて `DevelopViewModel.updateMask(id:_:)` 経由で行う。`parameters` へ代入し直す
/// ことで VM 側の didSet が再描画と永続化を予約する契約のため、`MaskLayer` を直接束縛しない。
struct MaskSectionView: View {
    @Bindable var developViewModel: DevelopViewModel

    /// 折りたたみ時にレイヤー数を示す。0 件のときは何も出さない。
    private var layerCountSummary: String? {
        let count = developViewModel.maskLayers.count
        guard count > 0 else { return nil }
        return String(localized: "develop.section.summary.maskLayers \(count)")
    }

    var body: some View {
        DevelopSectionCard("develop.section.masks", id: "masks", summary: layerCountSummary) {
            addButtons

            if !developViewModel.canEditMasks {
                Text("develop.mask.unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = developViewModel.aiMaskGenerationFailureMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
        // セクション（`DevelopSectionCard`）は展開時にしか `content` を評価しないため、
        // マスクセクションを開いたタイミングで無調整写真のベースプレビューを用意する
        // （`canEditMasks` が `previewImage` 依存のため、これが無いとボタンが永遠に無効のまま）。
        .task(id: developViewModel.currentPhotoID) {
            developViewModel.prepareMaskEditingPreviewIfNeeded()
        }
    }

    /// 選択中レイヤーの ID。削除直後など実体が無い ID は無効として扱う。
    private var selectedLayerID: UUID? {
        guard let id = developViewModel.selectedMaskLayerID,
              developViewModel.maskLayers.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private var addButtons: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.small) {
                Button("develop.mask.addLinearGradient", systemImage: "circle.lefthalf.striped.horizontal") {
                    developViewModel.addLinearGradientMask()
                }
                Button("develop.mask.addRadialGradient", systemImage: "circle.circle") {
                    developViewModel.addRadialGradientMask()
                }
                Button("develop.mask.addLuminanceRange", systemImage: "circle.lefthalf.filled") {
                    developViewModel.addLuminanceRangeMask()
                }
                Button("develop.mask.addBrush", systemImage: "paintbrush.pointed") {
                    developViewModel.addBrushMask()
                }
            }
            // AI マスク生成中は他種別の追加もブロックする。生成中に増えたレイヤーを
            // `regenerateAIMask`/`refineAIMask` が「AI 生成の成功」と誤判定する競合を防ぐ
            // （レビュー指摘）。
            .disabled(developViewModel.isGeneratingAIMask)

            HStack(spacing: Spacing.small) {
                Button("develop.mask.addForegroundSubject", systemImage: "person.and.background.dotted") {
                    Task { await developViewModel.addAIMask(kind: .foregroundSubject) }
                }
                Button("develop.mask.addPerson", systemImage: "person.fill") {
                    Task { await developViewModel.addAIMask(kind: .person) }
                }
                .help("develop.mask.addPerson.help")

                if developViewModel.isGeneratingAIMask {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("develop.mask.ai.generating")
                }
            }
            .disabled(developViewModel.isGeneratingAIMask)
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

            if developViewModel.maskNeedsRegeneration(layer) {
                Button {
                    Task { await developViewModel.regenerateAIMask(id: layer.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(developViewModel.isGeneratingAIMask)
                .help("develop.mask.regenerate.help")
                .accessibilityLabel("develop.mask.regenerate")
            }

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
        luminanceRangeSliders(id: id)
        brushEditor

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

    /// 輝度レンジ専用のスライダー。幾何ハンドルを持たないため操作はここだけで完結する。
    @ViewBuilder
    private func luminanceRangeSliders(id: UUID) -> some View {
        if let layer = developViewModel.maskLayers.first(where: { $0.id == id }),
           case .luminanceRange = layer.source {
            AdjustmentSlider(
                label: "develop.mask.luminanceLower",
                value: luminanceBinding(id, \.lowerBound, default: 0),
                range: 0...1,
                fractionDigits: 2
            )
            AdjustmentSlider(
                label: "develop.mask.luminanceUpper",
                value: luminanceBinding(id, \.upperBound, default: 1),
                range: 0...1,
                fractionDigits: 2
            )
            AdjustmentSlider(
                label: "develop.mask.smoothness",
                value: luminanceBinding(id, \.smoothness, default: 30),
                range: 0...100
            )
        }
    }

    /// ブラシ編集。`brushEdits` はどのベース生成子にも重ねられるので、レイヤー種別で出し分けない。
    /// 設定値はレイヤーではなく VM 側の「いま持っている筆」なので、`binding(_:_:default:)` ではなく
    /// `@Bindable` 経由で直接束縛する。
    @ViewBuilder
    private var brushEditor: some View {
        Toggle("develop.mask.brush.paintMode", isOn: $developViewModel.isBrushPaintMode)
            .toggleStyle(.checkbox)
            .disabled(!developViewModel.canEditMasks)

        if developViewModel.isBrushPaintMode {
            AdjustmentSlider(
                label: "develop.mask.brush.size",
                value: $developViewModel.brushRadius,
                range: DevelopViewModel.brushRadiusRange,
                neutral: DevelopViewModel.defaultBrushRadius,
                fractionDigits: 3
            )
            AdjustmentSlider(
                label: "develop.mask.brush.hardness",
                value: $developViewModel.brushHardness,
                range: 0...100,
                neutral: 50
            )
            AdjustmentSlider(
                label: "develop.mask.brush.opacity",
                value: $developViewModel.brushOpacity,
                range: 0...100,
                neutral: 100
            )

            HStack(spacing: Spacing.small) {
                Toggle("develop.mask.brush.eraser", isOn: $developViewModel.isBrushEraserMode)
                    .toggleStyle(.checkbox)
                Spacer(minLength: Spacing.small)
                Button("develop.mask.brush.undo", systemImage: "arrow.uturn.backward") {
                    developViewModel.undoLastBrushStroke()
                }
                .labelStyle(.iconOnly)
                .disabled(!developViewModel.canUndoBrushStroke)
            }
        }

        if let message = developViewModel.brushStrokeLimitReachedMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
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

    /// 輝度レンジのペイロード 1 フィールドを読み書きする束縛。
    private func luminanceBinding(
        _ id: UUID,
        _ keyPath: WritableKeyPath<LuminanceRangeMask, Double>,
        default defaultValue: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                guard let layer = developViewModel.maskLayers.first(where: { $0.id == id }),
                      case .luminanceRange(let mask) = layer.source else { return defaultValue }
                return mask[keyPath: keyPath]
            },
            set: { newValue in
                developViewModel.updateMask(id: id) { layer in
                    guard case .luminanceRange(var mask) = layer.source else { return }
                    mask[keyPath: keyPath] = newValue
                    layer.source = .luminanceRange(mask)
                }
            }
        )
    }
}
