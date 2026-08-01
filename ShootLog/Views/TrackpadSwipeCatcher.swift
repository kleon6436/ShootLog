import AppKit
import SwiftUI

// トラックパッドの2本指スクロールを捕捉して SwiftUI 側へ通知する AppKit ブリッジ。
//
// SwiftUI の DragGesture はマウスボタンドラッグ専用で、トラックパッドの2本指スワイプ
// （= スクロールイベント）を受け取れない。そのため NSView の scrollWheel(with:) を
// 直接オーバーライドして捕捉する。
//
// スクロールの用途はズーム状態で切り替える。
// - fit 倍率（isSwipeEnabled == true）: 水平スワイプを写真切替として扱う。
//   生の scrollWheel は1回の物理スワイプで数十イベント発火するため、水平方向のデルタを
//   蓄積して閾値到達時に一度だけコミットし、次に指が触れる（phase == .began）まで
//   ロックすることで「1スワイプ = 1コールバック」を保証する。
// - ズーム中（isSwipeEnabled == false）: 閾値判定を挟まず、各イベントのデルタを
//   そのまま onScrollDelta へ流して即時パンに使う。
//
// 使用例（フルスクリーンモードでの写真切替とズーム中のパン）:
//
//     PhotoViewerView(photo: vm.selectedPhoto, editInfo: vm.currentEditInfo)
//         .overlay {
//             TrackpadSwipeCatcher(
//                 // ズーム中（scale > 1.0）はスワイプではなくパンへ振り分ける
//                 isSwipeEnabled: effectiveScale <= 1.0,
//                 onSwipeLeft: { vm.noteUserActivity(); vm.selectNext() },
//                 onSwipeRight: { vm.noteUserActivity(); vm.selectPrevious() },
//                 onScrollDelta: { delta in panByScroll(delta) }
//             )
//         }
//
// マウスイベントは一切奪わないため、重ねた PhotoViewerView や HUD のボタンは
// これまで通りクリックできる（下記 hitTest の実装を参照）。
struct TrackpadSwipeCatcher: NSViewRepresentable {
    /// スクロールを写真切替スワイプとして扱うかどうか。false の間はスワイプ判定を
    /// 行わず、スクロールデルタを onScrollDelta へそのまま流す（ズーム中のパン用）
    var isSwipeEnabled: Bool = true

    /// スワイプ中にコミットする水平方向の累積移動量（ポイント）
    var threshold: CGFloat = 50

    /// 指が離れた（phase == .ended）時点でコミットする水平方向の累積移動量（ポイント）。
    /// threshold に届かない素早いフリックを拾うため threshold より小さい値にする
    var releaseThreshold: CGFloat = 20

    /// 左方向へのスワイプ。「次の写真へ進む」操作への割り当てを想定する
    var onSwipeLeft: () -> Void

    /// 右方向へのスワイプ。「前の写真へ戻る」操作への割り当てを想定する
    var onSwipeRight: () -> Void

    /// isSwipeEnabled == false の間、スクロールイベントごとに渡される生のデルタ。
    /// ズーム中のパンへ即時反映することを想定する（閾値によるコミットは行わない）
    var onScrollDelta: (CGSize) -> Void = { _ in }

    func makeNSView(context: Context) -> SwipeCatchingView {
        let view = SwipeCatchingView()
        applyConfiguration(to: view)
        return view
    }

    func updateNSView(_ nsView: SwipeCatchingView, context: Context) {
        applyConfiguration(to: nsView)
    }

    private func applyConfiguration(to view: SwipeCatchingView) {
        view.threshold = threshold
        view.releaseThreshold = releaseThreshold
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        view.onScrollDelta = onScrollDelta
        view.isSwipeEnabled = isSwipeEnabled
    }

    // MARK: - AppKit View

    @MainActor
    final class SwipeCatchingView: NSView {
        var threshold: CGFloat = 50
        var releaseThreshold: CGFloat = 20
        var onSwipeLeft: () -> Void = {}
        var onSwipeRight: () -> Void = {}
        var onScrollDelta: (CGSize) -> Void = { _ in }

        var isSwipeEnabled: Bool = true {
            didSet {
                // パンへ切り替わった時点で蓄積中のスワイプは破棄する
                if !isSwipeEnabled { resetAccumulation() }
            }
        }

        // 1ジェスチャー内で蓄積するスクロール量
        private var accumulatedX: CGFloat = 0
        private var accumulatedY: CGFloat = 0
        // コミット済みロック。次に指が触れた（phase == .began）時だけ解除する
        private var hasCommitted = false

        // スクロールイベントの時だけ自分を hit 対象にする。
        // それ以外（クリック・ドラッグ・ピンチ等）では nil を返して完全に透過させ、
        // 重ねた SwiftUI のボタンやジェスチャーのヒットテストを妨げない。
        // スワイプ判定中かパン中かに関わらずスクロールは受け取る必要があるため、
        // isSwipeEnabled では絞り込まない
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .scrollWheel else { return nil }
            return super.hitTest(point)
        }

        override func scrollWheel(with event: NSEvent) {
            // 通常のマウスホイールは精密デルタを持たず、スワイプの phase による
            // ロック解除もパン用の滑らかなデルタも得られないため対象外にする
            guard event.hasPreciseScrollingDeltas else {
                super.scrollWheel(with: event)
                return
            }

            // ズーム中はスワイプ判定を行わず、デルタをそのままパンへ渡す
            guard isSwipeEnabled else {
                onScrollDelta(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                return
            }

            // スワイプは phase / momentumPhase でジェスチャーの区切りを判定する
            guard !event.phase.isEmpty || !event.momentumPhase.isEmpty else {
                super.scrollWheel(with: event)
                return
            }

            if event.phase.contains(.began) {
                resetAccumulation()
            }
            if event.phase.contains(.cancelled) {
                resetAccumulation()
                return
            }

            // 慣性スクロール（momentumPhase）も蓄積対象にする。
            // コミット済みロックがあるため素早いフリックを拾っても二重発火しない
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY

            guard !hasCommitted else { return }

            let required = event.phase.contains(.ended) ? releaseThreshold : threshold
            // 縦スクロールを誤検知しないよう水平方向が優勢な場合だけ成立させる
            guard abs(accumulatedX) >= required, abs(accumulatedX) > abs(accumulatedY) else { return }

            hasCommitted = true
            if accumulatedX < 0 {
                onSwipeLeft()
            } else {
                onSwipeRight()
            }
        }

        private func resetAccumulation() {
            accumulatedX = 0
            accumulatedY = 0
            hasCommitted = false
        }
    }
}
