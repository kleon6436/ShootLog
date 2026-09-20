import SwiftUI

/// 現像パネル上部のプリセット行。プリセットの適用・保存・管理と、調整のコピー / ペースト / 元に戻すを提供する。
struct DevelopPresetBar: View {
    @Bindable var developViewModel: DevelopViewModel

    @State private var isSaveDialogPresented = false
    @State private var isManagerPresented = false
    @State private var newPresetName = ""
    @State private var includeMasksInPreset = false

    var body: some View {
        HStack(spacing: Spacing.small) {
            presetMenu

            actionButton(
                systemImage: "doc.on.doc",
                labelKey: "develop.copyAdjustments",
                shortcut: KeyboardShortcut("c", modifiers: [.command, .option]),
                isEnabled: developViewModel.canReset,
                action: developViewModel.copyAdjustments
            )
            actionButton(
                systemImage: "doc.on.clipboard",
                labelKey: "develop.pasteAdjustments",
                shortcut: KeyboardShortcut("v", modifiers: [.command, .option]),
                isEnabled: developViewModel.canPaste,
                action: developViewModel.pasteAdjustments
            )
            actionButton(
                systemImage: "arrow.uturn.backward",
                labelKey: "develop.undo",
                shortcut: KeyboardShortcut("z", modifiers: [.command, .option]),
                isEnabled: developViewModel.canUndo,
                action: developViewModel.undoLastApply
            )
        }
        // `.alert` は Toggle のようなカスタムコントロールを描画しないため、
        // 「マスクを含める」を置ける sheet に統一する。
        .sheet(isPresented: $isSaveDialogPresented) { savePresetSheet }
        .sheet(isPresented: $isManagerPresented) {
            DevelopPresetManagerSheet(developViewModel: developViewModel)
        }
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("develop.preset.saveTitle")
                .font(.headline)

            TextField("develop.preset.namePlaceholder", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("develop.preset.namePlaceholder")

            if !developViewModel.maskLayers.isEmpty {
                Toggle("develop.preset.includeMasks", isOn: $includeMasksInPreset)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("common.cancel", role: .cancel) { dismissSaveDialog() }
                    .keyboardShortcut(.cancelAction)
                Button("develop.preset.save") {
                    developViewModel.saveCurrentAsPreset(name: newPresetName, includeMasks: includeMasksInPreset)
                    dismissSaveDialog()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.large)
        .frame(width: 320)
    }

    private func dismissSaveDialog() {
        isSaveDialogPresented = false
        newPresetName = ""
        includeMasksInPreset = false
    }

    private var presetMenu: some View {
        Menu {
            if developViewModel.presets.isEmpty {
                Text("develop.preset.empty")
            } else {
                ForEach(developViewModel.presets) { preset in
                    Menu(preset.name) {
                        Button("develop.preset.apply") {
                            developViewModel.applyPreset(preset, relative: false)
                        }
                        Button("develop.preset.applyRelative") {
                            developViewModel.applyPreset(preset, relative: true)
                        }
                        // マスクを持たないプリセットでは選択肢が無意味なので出さない。
                        if !preset.parameters.masks.isEmpty {
                            Divider()
                            Button("develop.preset.applyWithMasks") {
                                developViewModel.applyPreset(preset, relative: false, includeMasks: true)
                            }
                            Button("develop.preset.applyRelativeWithMasks") {
                                developViewModel.applyPreset(preset, relative: true, includeMasks: true)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("develop.preset.saveCurrent") { isSaveDialogPresented = true }
                .disabled(!developViewModel.canReset)
            Button("develop.preset.manage") { isManagerPresented = true }
                .disabled(developViewModel.presets.isEmpty)
        } label: {
            Label("develop.preset.menu", systemImage: "square.stack.3d.up")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private func actionButton(
        systemImage: String,
        labelKey: LocalizedStringKey,
        shortcut: KeyboardShortcut,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isEnabled)
        .keyboardShortcut(shortcut)
        .help(labelKey)
        .accessibilityLabel(labelKey)
    }
}

/// プリセットの名前変更・削除を行うシート。
private struct DevelopPresetManagerSheet: View {
    @Bindable var developViewModel: DevelopViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("develop.preset.manageTitle").font(.headline)
                Spacer()
                Button("develop.preset.done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.medium)

            Divider()

            if developViewModel.presets.isEmpty {
                ContentUnavailableView("develop.preset.empty", systemImage: "square.stack.3d.up.slash")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(developViewModel.presets) { preset in
                        DevelopPresetRow(
                            preset: preset,
                            onRename: { developViewModel.renamePreset(preset, to: $0) },
                            onDelete: { developViewModel.deletePreset(preset) }
                        )
                    }
                }
            }
        }
        .frame(width: 360, height: 320)
    }
}

private struct DevelopPresetRow: View {
    let preset: DevelopPreset
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var editedName: String = ""

    var body: some View {
        HStack {
            TextField("develop.preset.namePlaceholder", text: $editedName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onRename(editedName) }
                .accessibilityLabel("develop.preset.namePlaceholder")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("common.delete")
            .accessibilityLabel("common.delete")
        }
        .onAppear { editedName = preset.name }
    }
}
