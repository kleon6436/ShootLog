import SwiftUI

// アプリ設定画面（Settings Scene から⌘,またはアプリメニュー「設定…」で開かれる）
// 現時点では設定項目の内容が未確定のため、最小構成のプレースホルダーとして「一般」タブのみを用意する
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("一般", systemImage: "gearshape")
                }
        }
        .frame(width: 400, height: 200)
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
}
