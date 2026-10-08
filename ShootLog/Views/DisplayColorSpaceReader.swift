import AppKit
import SwiftUI

/// ビューアが載っているディスプレイの色空間を報告する AppKit ブリッジ。
///
/// ウィンドウが別ディスプレイへ移動したとき（`NSWindow.didChangeScreenNotification`）と、
/// ディスプレイ構成が変わったとき（`NSApplication.didChangeScreenParametersNotification`）に
/// 最新の色空間を通知する。P3 ディスプレイでの現像プレビューを P3 書き出しの見えに合わせるために使う。
struct DisplayColorSpaceReader: NSViewRepresentable {

    /// 現在のディスプレイの色空間。取得できないときは `nil`（呼び出し側で sRGB 扱い）。
    var onChange: (CGColorSpace?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
        nsView.reportCurrent()
    }

    @MainActor
    final class ReaderView: NSView {
        var onChange: ((CGColorSpace?) -> Void)?

        /// 直近に通知した色空間。重複通知（SwiftUI の頻繁な updateNSView など）を抑える。
        /// 外側の Optional は「未通知」、内側の nil は「取得できなかった」を表す。
        /// ICC ベースのディスプレイ色空間は `CGColorSpace.name` が nil になるため、名前ではなく
        /// `CFEqual` で比較する（名前比較だと初回以降のディスプレイ間移動がすべて抑止されてしまう）
        private var lastReported: CGColorSpace??

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(displayChanged),
                    name: NSWindow.didChangeScreenNotification, object: window
                )
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(displayChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
            reportCurrent()
        }

        @objc private func displayChanged() {
            reportCurrent()
        }

        func reportCurrent() {
            let colorSpace = (window?.screen ?? NSScreen.main)?.colorSpace?.cgColorSpace
            if case .some(let previous) = lastReported, Self.isSameColorSpace(previous, colorSpace) {
                return
            }
            lastReported = .some(colorSpace)
            onChange?(colorSpace)
        }

        private static func isSameColorSpace(_ lhs: CGColorSpace?, _ rhs: CGColorSpace?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case let (lhs?, rhs?):
                return CFEqual(lhs, rhs)
            default:
                return false
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
