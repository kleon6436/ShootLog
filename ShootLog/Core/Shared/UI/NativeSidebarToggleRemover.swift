import AppKit
import SwiftUI

// ネイティブtoolbarを完全に外し、アプリ管理のヘッダーバーへ置き換えるための
// AppKitブリッジ。これによりシステム挿入のサイドバートグル自体を発生源から断つ。
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ nsView: GuardView, context: Context) {
        nsView.applyWindowConfiguration()
    }

    @MainActor
    final class GuardView: NSView {
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

            // NavigationSplitView でネイティブ toolbar が再生成されると
            // デフォルトのサイドバー開閉ボタンが復活するため、発生源を無効化する。
            if window.toolbar != nil {
                window.toolbar = nil
            }

            hideStandardToolbarButton(in: window)

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true

            if #available(macOS 15, *) {
                window.titlebarSeparatorStyle = .none
            }
        }

        // toolbar本体がnilでも、標準toolbarボタンが再表示されるケースがあるため毎回潰す。
        private func hideStandardToolbarButton(in window: NSWindow) {
            guard let toolbarButton = window.standardWindowButton(.toolbarButton) else {
                return
            }

            toolbarButton.isHidden = true
            toolbarButton.alphaValue = 0
            toolbarButton.isEnabled = false
        }
    }
}
