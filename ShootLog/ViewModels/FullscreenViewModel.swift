import AppKit
import Foundation

// フルスクリーンモード専用のViewModel。写真データは ContentViewModel への薄いプロキシに徹し、
// 独自状態としてHUD（上部/下部オーバーレイ＋ウィンドウツールバー）の自動隠れ制御のみを持つ。
// ズーム倍率・パンオフセットは写真切替やモード往復で必ずリセットされる必要があるため、
// ViewModelBoxにキャッシュされる本ViewModelではなくFullscreenModeViewのローカル@Stateで保持する
@Observable
@MainActor
final class FullscreenViewModel: ContentViewModelProxy {
    let content: ContentViewModel

    // HUDとウィンドウツールバーの表示状態。falseの間はHUDのボタンを描画せず、
    // ヒットテストも行わないため誤クリックが発生しない
    private(set) var isHUDVisible = true

    // 無操作でHUDを隠すまでの時間
    private let idleInterval: TimeInterval = 2.8

    // アイドル判定の周期。マウス移動ごとにTaskを作り直すとイベント量に対して過剰なため、
    // 最終操作時刻を記録して単一のポーリングTaskで判定する
    private let idlePollInterval: Duration = .milliseconds(300)

    // 自動的に隠してはいけない状態（分析シートやエラーAlert表示中、
    // HUD内要素にキーボードフォーカスがある等）。
    // 高頻度で更新されるためObservationの追跡対象から外す
    @ObservationIgnored private var isHUDPinned = true
    @ObservationIgnored private var lastActivityAt = Date()
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    init(content: ContentViewModel) {
        self.content = content
    }

    // 委譲プロパティ・メソッドは ContentViewModelProxy のデフォルト実装に任せる

    func toggleFavorite() { content.toggleFavorite() }

    // お気に入りのみ表示の絞り込み（visiblePhotos / visibleIndex / visibleCounterText）は
    // ContentViewModelProxy のデフォルト実装を使う

    // MARK: - HUD 自動隠れ

    // 分析シート・エラーAlertの表示中はHUDを自動的に隠さないための判定
    var isModalPresented: Bool { content.showAnalysis || content.error != nil }

    // フルスクリーン表示開始時（ViewのonAppear）に呼ぶ。
    // ViewModelBoxのキャッシュにより前回の非表示状態が残るため、必ず表示状態から始める
    func beginHUDSession() {
        isHUDVisible = true
        content.isToolbarVisible = true
        lastActivityAt = Date()
        idleTask?.cancel()
        let pollInterval = idlePollInterval
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.evaluateIdleState()
            }
        }
    }

    // フルスクリーン終了時（ViewのonDisappear）に呼ぶ。
    // 隠したままモードを抜けるとツールバーが復帰しないため必ず表示へ戻す
    func endHUDSession() {
        idleTask?.cancel()
        idleTask = nil
        isHUDPinned = true
        // 差分ガードに頼らず必ず両方を復帰させる。隠したままモードを抜けると
        // サイドバー/スライドショーでツールバーが戻らなくなるため
        isHUDVisible = true
        content.isToolbarVisible = true
    }

    // マウス移動・キー操作・ボタン操作などのユーザー操作を通知する。
    // 隠れていたHUDを再表示し、アイドル計測を最初からやり直す
    func noteUserActivity() {
        lastActivityAt = Date()
        setHUDVisible(true)
    }

    // HUDを隠してはいけない状態かどうかをViewから通知する
    func setHUDPinned(_ pinned: Bool) {
        isHUDPinned = pinned
        if pinned {
            noteUserActivity()
        } else {
            lastActivityAt = Date()
        }
    }

    // MARK: - Private

    private func evaluateIdleState() {
        guard isHUDVisible, !isHUDPinned else { return }
        // VoiceOver有効時は自動的に隠さない。マウス移動なしでもキーボードのみで
        // お気に入り/回転/閉じるへ到達できる必要があるため（判定時点の最新状態を読む）
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        guard Date().timeIntervalSince(lastActivityAt) >= idleInterval else { return }
        setHUDVisible(false)
    }

    // HUDの表示状態をウィンドウツールバーの可視性（ContentViewModel経由で
    // WindowChromeConfiguratorへ渡る）と同期させる
    private func setHUDVisible(_ visible: Bool) {
        guard isHUDVisible != visible else { return }
        isHUDVisible = visible
        content.isToolbarVisible = visible
    }
}
