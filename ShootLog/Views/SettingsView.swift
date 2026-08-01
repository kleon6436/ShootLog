import SwiftUI

// アプリ設定画面（Settings Scene から⌘,またはアプリメニュー「設定…」で開かれる）
// 「一般」タブは設定項目が未確定のためプレースホルダー、「連携アプリ」タブで外部アプリ連携を管理する
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
        .frame(width: 460, height: 380)
    }
}

// 「一般」タブの中身（プレースホルダー）
private struct GeneralSettingsTab: View {
    var body: some View {
        Form {
            Text("設定項目は今後追加予定です")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: IntegrationAppSetting.self, inMemory: true)
}
