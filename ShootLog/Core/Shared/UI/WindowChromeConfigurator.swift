import AppKit
import SwiftUI

// ウィンドウの chrome（タイトルバー）を表示モードに応じて構成する AppKit ブリッジ。
//
// - sidebar モード: 標準 NSToolbar をそのまま使う。タイトル文字だけを隠し、
//   タイトルバーの実体（不透明な背景・レイアウト領域）は残す。これにより
//   「サイドバー表示中は信号機とサイドバートグルがサイドバー内、非表示時は
//   ツールバー左端」という Xcode 同様の macOS 標準挙動がそのまま働く。
// - fullscreen / slideshow モード: 独自ヘッダーバー（ContentView）を
//   タイトルバー領域に重ねるため、タイトルバーを透過させ全面をコンテンツにする。
struct WindowChromeConfigurator: NSViewRepresentable {
    // 標準ツールバーを使うモードかどうか（sidebar モードのみ true）
    let usesStandardToolbar: Bool

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.usesStandardToolbar = usesStandardToolbar
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.usesStandardToolbar = usesStandardToolbar
        nsView.applyWindowConfiguration()
    }

    @MainActor
    final class ChromeView: NSView {
        // 標準ツールバーを使うモードかどうか。updateNSView から更新される
        var usesStandardToolbar: Bool = true
        private weak var observedWindow: NSWindow?
        // 独自ヘッダー時に window から外した NSToolbar。SwiftUI は一度外したツールバーを
        // 再生成しないことがあるため、インスタンスを保持して sidebar モード復帰時に再アタッチする
        private var detachedToolbar: NSToolbar?

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

            // タイトル文字は全モードで非表示（ツールバーのみの Xcode 風の見た目）
            window.titleVisibility = .hidden

            // ツールバー自体の有無は AppKit 側で切り替える。SwiftUI の
            // .toolbar(.hidden, for: .windowToolbar) はタイトルバーごと隠して
            // 信号機まで消え、isVisible = false では 28pt のタイトルバーが残って
            // 独自ヘッダーバーを覆ってしまうため、独自ヘッダー時は toolbar 自体を外す
            if usesStandardToolbar {
                // モード往復でツールバーが消えたままになる（モード切替・フォルダを開く等の
                // ボタンが失われる）のを防ぐため、外しておいたインスタンスを戻す
                if window.toolbar == nil, let detachedToolbar {
                    window.toolbar = detachedToolbar
                }
                window.toolbar?.isVisible = true
                detachedToolbar = nil
            } else if let toolbar = window.toolbar {
                detachedToolbar = toolbar
                window.toolbar = nil
            }

            if usesStandardToolbar {
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
            } else {
                // 独自ヘッダーバーを重ねるためタイトルバーを透過させる
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = true
                if #available(macOS 15, *) {
                    window.titlebarSeparatorStyle = .none
                }
            }
        }
    }
}
