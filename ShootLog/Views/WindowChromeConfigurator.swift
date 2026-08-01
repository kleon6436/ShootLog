import AppKit
import SwiftUI

// ウィンドウの chrome（タイトルバー）を構成する AppKit ブリッジ。
// 全表示モード（sidebar/fullscreen/slideshow）が標準 NSToolbar を使うため、
// タイトル文字だけを隠しつつタイトルバー領域はサイドバー材質のフルハイト表示に統一する
// （「サイドバー表示中は信号機とサイドバートグルがサイドバー内、非表示時はツールバー左端」
// という Xcode 同様の macOS 標準挙動がそのまま働く）。
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView {
        ChromeView()
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.applyWindowConfiguration()
    }

    @MainActor
    final class ChromeView: NSView {
        private weak var observedWindow: NSWindow?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            observedWindow = newWindow
            applyWindowConfiguration(to: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observedWindow = window
            applyWindowConfiguration(to: window)
        }

        override func layout() {
            super.layout()
            applyWindowConfiguration()
        }

        func applyWindowConfiguration() {
            applyWindowConfiguration(to: observedWindow ?? window)
        }

        private func applyWindowConfiguration(to window: NSWindow?) {
            guard let window else { return }

            // タイトル文字は非表示（ツールバーのみの Xcode 風の見た目）
            window.titleVisibility = .hidden
            window.toolbar?.isVisible = true

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
    }
}
