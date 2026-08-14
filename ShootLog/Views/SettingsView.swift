import SwiftUI

// アプリ設定画面（Settings Scene から⌘,またはアプリメニュー「設定…」で開かれる）
// 「一般」タブで起動時の既定値とパフォーマンス設定を、「連携アプリ」タブで外部アプリ連携を管理する
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("settings.tab.general", systemImage: "gearshape")
                }

            IntegrationSettingsTab()
                .tabItem {
                    Label("settings.tab.integration", systemImage: "app.connected.to.app.below.fill")
                }

            AcknowledgementsView()
                .tabItem {
                    Label("settings.tab.acknowledgements", systemImage: "text.book.closed")
                }
        }
        // 高さは「一般」タブの5セクションがスクロールなしで収まる値に合わせる
        .frame(width: 460, height: 520)
    }
}

// 「一般」タブの中身。設定値はすべて UserDefaults（AppSettingsKeys）へ保存し、
// ContentViewModel / SlideshowViewModel / ImageLoader が起動時に既定値として読み込む
private struct GeneralSettingsTab: View {
    @AppStorage(AppSettingsKeys.defaultViewModeID)
    private var defaultViewModeID = AppSettingsKeys.defaultViewModeIDDefault
    @AppStorage(AppSettingsKeys.defaultFavoritesOnly)
    private var defaultFavoritesOnly = AppSettingsKeys.defaultFavoritesOnlyDefault
    @AppStorage(AppSettingsKeys.defaultInspectorVisible)
    private var defaultInspectorVisible = AppSettingsKeys.defaultInspectorVisibleDefault
    @AppStorage(AppSettingsKeys.slideshowAutoplay)
    private var slideshowAutoplay = AppSettingsKeys.slideshowAutoplayDefault
    @AppStorage(AppSettingsKeys.slideshowInterval)
    private var slideshowInterval = AppSettingsKeys.slideshowIntervalDefault
    @AppStorage(AppSettingsKeys.thumbnailQuality)
    private var thumbnailQualityRaw = ThumbnailQuality.standard.rawValue
    @AppStorage(AppSettingsKeys.networkConcurrency)
    private var networkConcurrency = AppSettingsKeys.networkConcurrencyDefault
    @AppStorage(AppSettingsKeys.folderHistoryLimit)
    private var folderHistoryLimit = AppSettingsKeys.folderHistoryLimitDefault

    @State private var showClearCacheConfirm = false
    @State private var showQualityChangeNotice = false

    var body: some View {
        Form {
            Section("settings.section.display") {
                Picker("settings.startupMode", selection: $defaultViewModeID) {
                    ForEach(ViewModeRegistry.shared.enabledModes, id: \.id) { mode in
                        Text(mode.displayName).tag(mode.id)
                    }
                }
                .accessibilityLabel("settings.startupMode")
                Toggle("settings.startupFavoritesOnly", isOn: $defaultFavoritesOnly)
                Toggle("settings.startupInspector", isOn: $defaultInspectorVisible)
            }

            Section("settings.section.slideshow") {
                Toggle("settings.slideshow.autoplay", isOn: $slideshowAutoplay)
                Stepper(
                    "settings.slideshow.interval \(slideshowInterval, specifier: "%.1f")",
                    value: $slideshowInterval, in: 1.0...10.0, step: 0.5
                )
                .accessibilityLabel("a11y.settings.slideshowInterval")
            }

            Section("settings.section.performance") {
                Picker("settings.thumbnailQuality", selection: $thumbnailQualityRaw) {
                    ForEach(ThumbnailQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality.rawValue)
                    }
                }
                .accessibilityLabel("settings.thumbnailQuality")
                .onChange(of: thumbnailQualityRaw) { _, _ in
                    showQualityChangeNotice = true
                }
                Stepper(
                    "settings.networkConcurrency \(networkConcurrency)",
                    value: $networkConcurrency, in: 1...8
                )
                .accessibilityLabel("a11y.settings.networkConcurrency")
                Text("settings.performance.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.section.cache") {
                Button("settings.cache.clear", role: .destructive) {
                    showClearCacheConfirm = true
                }
                .accessibilityLabel("settings.cache.clear")
            }

            Section("settings.section.folderHistory") {
                Stepper("settings.folderHistory.limit \(folderHistoryLimit)", value: $folderHistoryLimit, in: 5...20)
                    .accessibilityLabel("a11y.settings.folderHistoryLimit")
            }
        }
        .formStyle(.grouped)
        .alert("settings.cache.clear.confirm.title", isPresented: $showClearCacheConfirm) {
            Button("common.delete", role: .destructive) {
                // ファイル削除はMainActor外で実行する
                Task.detached(priority: .utility) { ImageLoader.shared.clearDiskCache() }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.cache.clear.confirm.message")
        }
        .alert("settings.quality.changed.title", isPresented: $showQualityChangeNotice) {
            Button("common.ok") {}
        } message: {
            Text("settings.quality.changed.message")
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: IntegrationAppSetting.self, inMemory: true)
}
