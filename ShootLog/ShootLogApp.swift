import SwiftUI
import SwiftData

@main
struct ShootLogApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // MainActor外でImageLoaderを先行初期化し、初回サムネイル読み込み時の
                // ディスクI/O（キャッシュディレクトリ作成）がMainActor上で走るのを防ぐ
                .task {
                    Task.detached(priority: .utility) {
                        _ = ImageLoader.shared
                    }
                }
        }
        // SwiftDataモデルをすべて登録
        .modelContainer(for: [Photo.self, EditInfo.self, FolderHistory.self])
        // sidebar モードは標準ツールバーを使うため .hiddenTitleBar は指定しない
        // （.hiddenTitleBar はツールバー領域自体を潰すため）。タイトル文字の非表示と、
        // fullscreen/slideshow モードでのタイトルバー透過は WindowChromeConfigurator が担当する
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            // 「ファイル」メニューに「フォルダを開く…」を追加する
            CommandGroup(after: .newItem) {
                OpenFolderCommand()
            }
            // Viewメニューの標準的なサイドバー区画に左サイドバー開閉を配置する
            CommandGroup(replacing: .sidebar) {
                ToggleSidebarCommand()
            }
            // 右側のEXIFパネルはインスペクタ相当として直後に配置する
            CommandGroup(after: .sidebar) {
                ToggleInspectorCommand()
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

// 表示メニュー相当の左サイドバー開閉コマンド
private struct ToggleSidebarCommand: View {
    @FocusedValue(\.toggleSidebarAction) private var toggleSidebar: (() -> Void)?
    @FocusedValue(\.sidebarVisibilityState) private var isSidebarVisible: Bool?

    var body: some View {
        Button(isSidebarVisible == true ? "サイドバーを隠す" : "サイドバーを表示") { toggleSidebar?() }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(toggleSidebar == nil)
    }
}

// ViewメニューのEXIFパネル開閉コマンド
private struct ToggleInspectorCommand: View {
    @FocusedValue(\.toggleInspectorAction) private var toggleInspector: (() -> Void)?
    @FocusedValue(\.inspectorVisibilityState) private var isInspectorVisible: Bool?

    var body: some View {
        Button(isInspectorVisible == true ? "EXIFパネルを隠す" : "EXIFパネルを表示") { toggleInspector?() }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(toggleInspector == nil)
    }
}
