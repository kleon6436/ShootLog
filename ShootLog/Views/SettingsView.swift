import SwiftUI

// アプリ設定画面（Settings Scene から⌘,またはアプリメニュー「設定…」で開かれる）
// 「一般」タブで起動時の既定値とパフォーマンス設定を、「連携アプリ」タブで外部アプリ連携を管理する
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("一般", systemImage: "gearshape")
                }

            IntegrationSettingsTab()
                .tabItem {
                    Label("連携アプリ", systemImage: "app.connected.to.app.below.fill")
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
            Section("表示") {
                Picker("起動時に表示するモード", selection: $defaultViewModeID) {
                    ForEach(ViewModeRegistry.shared.enabledModes, id: \.id) { mode in
                        Text(mode.displayName).tag(mode.id)
                    }
                }
                .accessibilityLabel("起動時に表示するモード")
                Toggle("起動時にお気に入りのみ表示する", isOn: $defaultFavoritesOnly)
                Toggle("起動時にEXIFパネルを表示する", isOn: $defaultInspectorVisible)
            }

            Section("スライドショー") {
                Toggle("自動再生を有効にする", isOn: $slideshowAutoplay)
                Stepper(
                    "再生間隔: \(slideshowInterval, specifier: "%.1f")秒",
                    value: $slideshowInterval, in: 1.0...10.0, step: 0.5
                )
                .accessibilityLabel("スライドショー再生間隔")
            }

            Section("パフォーマンス") {
                Picker("サムネイル画質", selection: $thumbnailQualityRaw) {
                    ForEach(ThumbnailQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality.rawValue)
                    }
                }
                .accessibilityLabel("サムネイル画質")
                .onChange(of: thumbnailQualityRaw) { _, _ in
                    showQualityChangeNotice = true
                }
                Stepper(
                    "ネットワークボリューム同時読み込み数: \(networkConcurrency)件",
                    value: $networkConcurrency, in: 1...8
                )
                .accessibilityLabel("ネットワークボリューム同時読み込み数")
                Text("画質・同時読み込み数の変更は次回アプリ起動後に反映されます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("キャッシュ") {
                Button("ディスクキャッシュを削除", role: .destructive) {
                    showClearCacheConfirm = true
                }
                .accessibilityLabel("ディスクキャッシュを削除")
            }

            Section("フォルダ履歴") {
                Stepper("保持件数: \(folderHistoryLimit)件", value: $folderHistoryLimit, in: 5...20)
                    .accessibilityLabel("フォルダ履歴の保持件数")
            }
        }
        .formStyle(.grouped)
        .alert("ディスクキャッシュを削除しますか？", isPresented: $showClearCacheConfirm) {
            Button("削除", role: .destructive) {
                // ファイル削除はMainActor外で実行する
                Task.detached(priority: .utility) { ImageLoader.shared.clearDiskCache() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("次回表示時にサムネイルが再生成されます。")
        }
        .alert("画質設定を変更しました", isPresented: $showQualityChangeNotice) {
            Button("OK") {}
        } message: {
            Text("既存のキャッシュ済みサムネイルは古い画質のまま残ります。反映するにはディスクキャッシュの削除とアプリの再起動が必要です。")
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: IntegrationAppSetting.self, inMemory: true)
}
