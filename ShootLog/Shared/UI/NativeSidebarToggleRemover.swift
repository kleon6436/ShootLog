import AppKit
import SwiftUI

// SwiftUIの.toolbar(removing: .sidebarToggle)だけでは、macOS 26でAppKitが
// ウィンドウのNSToolbarへ自動挿入するネイティブのサイドバートグルボタンを
// 抑止できない。自前の開閉トグルボタンと二重に表示され紛らわしくなるため、
// AppKit階層に手を伸ばしてネイティブトグルのみを物理的に取り除く。
struct NativeSidebarToggleRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ nsView: GuardView, context: Context) {}

    final class GuardView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // 初回アタッチ時に早期の適用機会を作るため、レイアウトパスをトリガーする
            // （実際の適用はlayout()側で行う）
            needsLayout = true
        }

        override func layout() {
            super.layout()
            // NSToolbarへのネイティブトグル自動挿入タイミングはウィンドウ復元・モード切替・
            // 初回起動時などで前後するため、単発実行では未挿入時に取りこぼして二度と再試行
            // されないことがあった。layout()はAppKitがレイアウト変更のたびに繰り返し呼ぶため、
            // ここに置くことで未挿入なら次のレイアウトパスで自動的に再試行される、明示的な
            // リトライ機構不要の継続適用になる。
            removeNativeSidebarToggleButton()
        }

        // SwiftUIの.toolbar(removing: .sidebarToggle)はNavigationSplitViewが自動挿入する
        // "default item"のSwiftUI側候補を除去するだけで、実機検証の結果、macOS 26では
        // ウィンドウのNSToolbarに対してAppKitが直接挿入するネイティブのサイドバートグル
        // ボタン（NSToolbarItem.Identifier.toggleSidebar）は消えないことを確認した。
        // そのためAppKit階層に直接手を伸ばし、ウィンドウのtoolbar.itemsから
        // 該当アイテムを探して物理的に取り除く。
        private func removeNativeSidebarToggleButton() {
            guard let toolbar = window?.toolbar else { return }
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .toggleSidebar }) {
                toolbar.removeItem(at: index)
            }
        }
    }
}
