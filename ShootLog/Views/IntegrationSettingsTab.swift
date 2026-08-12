import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// 設定画面の「連携アプリ」タブ。
// ビルトインアプリの有効/無効切替・表示順序の変更と、カスタムアプリの追加/削除を行う
struct IntegrationSettingsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \IntegrationAppSetting.sortOrder) private var settings: [IntegrationAppSetting]
    @State private var error: (any Error)?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(installedSettings) { setting in
                    settingRow(setting)
                }
                .onMove(perform: moveSettings)
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 8) {
                Button {
                    addCustomApp()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("integration.add")
                .accessibilityLabel("integration.add")

                Text("integration.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { synchronizeBuiltInSettings() }
        .alert("common.error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("common.ok") { error = nil }
        } message: {
            Text(error?.localizedDescription ?? "")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func settingRow(_ setting: IntegrationAppSetting) -> some View {
        let name = displayName(for: setting)

        HStack(spacing: 8) {
            Image(systemName: symbolName(for: setting))
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(name)

            Spacer()

            if setting.isCustom {
                Button(role: .destructive) {
                    remove(setting)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("a11y.integration.remove \(name)")
                .accessibilityLabel("a11y.integration.remove \(name)")
            }

            // ラベルは隠して accessibilityLabel で説明するため、
            // 空文字のラベルがローカライズキーとして抽出されないよう EmptyView を使う
            Toggle(isOn: Binding(
                get: { setting.isEnabled },
                set: { newValue in
                    setting.isEnabled = newValue
                    saveChanges()
                }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("a11y.integration.enable \(name)")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Display

    // 表示名。ビルトインはアダプター実装の表示名、カスタムは保存された名前を使う
    private func displayName(for setting: IntegrationAppSetting) -> String {
        if setting.isCustom {
            return setting.customDisplayName ?? setting.identifier
        }
        return builtInAdapter(for: setting)?.displayName ?? setting.identifier
    }

    private func symbolName(for setting: IntegrationAppSetting) -> String {
        if setting.isCustom {
            return CustomAppAdapter(id: setting.identifier, displayName: "").symbolName
        }
        return builtInAdapter(for: setting)?.symbolName ?? "app.dashed"
    }

    private func builtInAdapter(for setting: IntegrationAppSetting) -> (any ExternalAppProtocol)? {
        ExternalAppRegistry.shared.builtInAdapters.first { $0.id == setting.identifier }
    }

    // インストール済みのアプリのみ一覧に表示する（未インストールのビルトイン/カスタムは出さない）
    private var installedSettings: [IntegrationAppSetting] {
        settings.filter(isAvailable)
    }

    private func isAvailable(_ setting: IntegrationAppSetting) -> Bool {
        if setting.isCustom {
            return CustomAppAdapter(id: setting.identifier, displayName: "").isAvailable
        }
        return builtInAdapter(for: setting)?.isAvailable ?? false
    }

    // MARK: - Actions

    // 設定が未作成のビルトインアダプターを有効状態で追加する（初回表示時はビルトイン全件を生成する）
    private func synchronizeBuiltInSettings() {
        let existingIDs = Set(settings.map(\.identifier))
        let missingAdapters = ExternalAppRegistry.shared.builtInAdapters.filter {
            !existingIDs.contains($0.id)
        }
        guard !missingAdapters.isEmpty else { return }

        var nextSortOrder = (settings.map(\.sortOrder).max() ?? -1) + 1
        for adapter in missingAdapters {
            modelContext.insert(
                IntegrationAppSetting(
                    identifier: adapter.id,
                    isEnabled: true,
                    sortOrder: nextSortOrder,
                    isCustom: false
                )
            )
            nextSortOrder += 1
        }
        saveChanges()
    }

    // ドラッグ並べ替えの結果を sortOrder へ振り直す（表示中＝インストール済みの行同士の順序のみ更新する）
    private func moveSettings(from source: IndexSet, to destination: Int) {
        var reordered = installedSettings
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, setting) in reordered.enumerated() {
            setting.sortOrder = index
        }
        saveChanges()
    }

    private func remove(_ setting: IntegrationAppSetting) {
        modelContext.delete(setting)
        saveChanges()
    }

    // App ピッカーで選択したアプリをカスタム連携アプリとして追加する
    private func addCustomApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = String(localized: "openPanel.app.message")
        panel.prompt = String(localized: "openPanel.app.prompt")
        guard panel.runModal() == .OK, let appURL = panel.url else { return }

        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier else {
            error = ShootLogError.applicationInfoUnavailable(name: fallbackName)
            return
        }
        let name = bundle.infoDictionary?["CFBundleName"] as? String ?? fallbackName

        // ビルトイン・登録済みカスタムのどちらとも重複させない
        let isDuplicate = settings.contains { $0.identifier == bundleID }
            || ExternalAppRegistry.shared.builtInAdapters.contains { $0.id == bundleID }
        guard !isDuplicate else {
            error = ShootLogError.duplicateIntegrationApp(name: name)
            return
        }

        modelContext.insert(
            IntegrationAppSetting(
                identifier: bundleID,
                isEnabled: true,
                sortOrder: (settings.map(\.sortOrder).max() ?? -1) + 1,
                isCustom: true,
                customDisplayName: name
            )
        )
        saveChanges()
    }

    // 設定の永続化。失敗は握りつぶさずAlertで通知する
    private func saveChanges() {
        do {
            try modelContext.save()
        } catch {
            self.error = ShootLogError.settingsSaveFailed
        }
    }
}

#Preview {
    IntegrationSettingsTab()
        .modelContainer(for: IntegrationAppSetting.self, inMemory: true)
}
