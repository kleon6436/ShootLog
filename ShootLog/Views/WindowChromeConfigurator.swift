import AppKit
import SwiftUI

// ウィンドウの chrome（タイトルバー）を構成する AppKit ブリッジ。
// 全表示モード（sidebar/fullscreen/slideshow）が標準 NSToolbar を使うため、
// タイトル文字だけを隠しつつタイトルバー領域はサイドバー材質のフルハイト表示に統一する
// （「サイドバー表示中は信号機とサイドバートグルがサイドバー内、非表示時はツールバー左端」
// という Xcode 同様の macOS 標準挙動がそのまま働く）。
struct WindowChromeConfigurator: NSViewRepresentable {
    // メインウィンドウのフレームをmacOSの標準autosaveへ預ける。アプリの
    // UserDefaults内でメインウィンドウを識別できる、安定した名前を使う。
    private static let frameAutosaveName = "ShootLog.mainWindow"

    // ツールバーの可視性を呼び出し元が明示的に指定するための入力。デフォルトはtrueで既存動作を維持する。
    // フルスクリーンのHUD自動隠れ機能（isHUDVisibleと連動予定）から利用する
    var isToolbarVisible: Bool = true

    func makeNSView(context: Context) -> ChromeView {
        ChromeView()
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.applyWindowConfiguration(isToolbarVisible: isToolbarVisible)
    }

    @MainActor
    final class ChromeView: NSView {
        private weak var observedWindow: NSWindow?
        private weak var configuredWindow: NSWindow?
        private weak var configuredToolbar: NSToolbar?

        // SwiftUIのupdateNSView経由で渡される最新のツールバー可視性。
        // ウィンドウ移動などNSView側のライフサイクルコールバックでも参照できるよう保持する
        private var isToolbarVisible = true

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            observedWindow = newWindow
            if configuredWindow !== newWindow {
                configuredWindow = nil
                configuredToolbar = nil
            }
            applyWindowConfiguration(to: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observedWindow = window
            if configuredWindow !== window {
                configuredWindow = nil
                configuredToolbar = nil
            }
            applyWindowConfiguration(to: window)
        }

        override func layout() {
            super.layout()
            applyWindowConfiguration()
        }

        // SwiftUIのupdateNSViewから呼ばれる。最新のisToolbarVisibleを保持してから適用する
        func applyWindowConfiguration(isToolbarVisible: Bool) {
            self.isToolbarVisible = isToolbarVisible
            applyWindowConfiguration()
        }

        func applyWindowConfiguration() {
            applyWindowConfiguration(to: observedWindow ?? window)
        }

        private func applyWindowConfiguration(to window: NSWindow?) {
            guard let window else { return }

            // モード切替や子Viewの再描画ではNSViewRepresentableの更新・layoutが
            // 頻繁に呼ばれるため、ウィンドウ自身の設定は対象が変わった時だけ行う。
            if configuredWindow !== window {
                configuredWindow = window

                // setFrameAutosaveName(_:) は登録時に保存済みフレームを復元し、以後の
                // 移動・リサイズを自動保存する。configuredWindow のガード内に置くことで、
                // SwiftUIの再描画やlayout()のたびにフレームを再適用しない。
                window.setFrameAutosaveName(WindowChromeConfigurator.frameAutosaveName)

                // タイトル文字は非表示（ツールバーのみの Xcode 風の見た目）
                window.titleVisibility = .hidden

                // サイドバーの材質をタイトルバー領域まで伸ばす（Xcode/Finder と同じ
                // フルハイトサイドバー）ため fullSizeContentView を維持する。
                // 写真一覧のドラッグでウィンドウが動かないよう背景ドラッグは無効にする
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = false
                if #available(macOS 15, *) {
                    // サイドバー境界に追従する区切り線をシステムに任せる
                    window.titlebarSeparatorStyle = .automatic
                }
            }

            // NSToolbarはSwiftUIの構築順により後から差し替わる場合があるため、
            // toolbarインスタンスが変わった時に加えて、要求値と実際の可視性が
            // 食い違っている時（HUD自動隠れによるisToolbarVisibleの変化）も同期する。
            // 値が一致している場合は何もしないため、layout()の頻繁な呼び出しで
            // 隠した状態が強制的に戻されることはない
            if let toolbar = window.toolbar,
               configuredToolbar !== toolbar || toolbar.isVisible != isToolbarVisible {
                toolbar.isVisible = isToolbarVisible
                configuredToolbar = toolbar
            }
        }
    }
}
