import SwiftUI
import SwiftData

@main
struct ShootLogApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // SwiftDataモデルをすべて登録
        .modelContainer(for: [Photo.self, EditInfo.self, FolderHistory.self])
        // タイトルバー/ツールバーの二段表示を1行にまとめられないか試験適用(効果薄なら方針E不採用として記録)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            // 「ファイル」メニューに「フォルダを開く…」を追加する
            CommandGroup(after: .newItem) {
                OpenFolderCommand()
            }
        }

        // 設定画面（⌘,・アプリメニュー「設定…」はOSが自動配線する）
        Settings {
            SettingsView()
        }
    }
}

// ファイルメニューの「フォルダを開く…」コマンド
// FocusedValue 経由でフォーカス中ウィンドウの ContentViewModel.openFolder を呼ぶ
private struct OpenFolderCommand: View {
    @FocusedValue(\.openFolderAction) private var openFolder: (() -> Void)?

    var body: some View {
        Button("フォルダを開く…") { openFolder?() }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openFolder == nil)
    }
}
