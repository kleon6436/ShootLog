import Foundation

// フルスクリーンモード専用のViewModel。写真データは ContentViewModel への薄いプロキシに徹する。
// ズーム倍率・パンオフセットは写真切替やモード往復で必ずリセットされる必要があるため、
// ViewModelBoxにキャッシュされる本ViewModelではなくFullscreenModeViewのローカル@Stateで保持する
@Observable
@MainActor
final class FullscreenViewModel: ContentViewModelProxy {
    let content: ContentViewModel

    // HUD（上部/下部オーバーレイ＋ウィンドウツールバー）は常に表示する。
    // 無操作での自動非表示は使いづらいという判断で廃止した
    let isHUDVisible = true

    init(content: ContentViewModel) {
        self.content = content
    }

    // 委譲プロパティ・メソッドは ContentViewModelProxy のデフォルト実装に任せる

    func toggleFavorite() { content.toggleFavorite() }

    // お気に入りのみ表示の絞り込み（visiblePhotos / visibleIndex / visibleCounterText）は
    // ContentViewModelProxy のデフォルト実装を使う

    // MARK: - HUD

    // 分析シート・エラーAlert表示中かどうか。FullscreenModeView側の判定に使う
    var isModalPresented: Bool { content.showAnalysis || content.error != nil }

    // フルスクリーン表示開始時（ViewのonAppear）に呼ぶ
    func beginHUDSession() {
        content.isToolbarVisible = true
    }

    // フルスクリーン終了時（ViewのonDisappear）に呼ぶ
    func endHUDSession() {
        content.isToolbarVisible = true
    }

    // HUDは常時表示のため何もしない。FullscreenModeView側の多数の呼び出し箇所を
    // 変更せずに済むよう no-op として残す
    func noteUserActivity() {}

    // HUDは常時表示のため何もしない
    func setHUDPinned(_ pinned: Bool) {}
}
