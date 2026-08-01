import Foundation

// フルスクリーンモード専用のViewModel。独自状態は持たず ContentViewModel への薄いプロキシに徹する
@Observable
@MainActor
final class FullscreenViewModel: ContentViewModelProxy {
    let content: ContentViewModel

    init(content: ContentViewModel) {
        self.content = content
    }

    // 委譲プロパティ・メソッドは ContentViewModelProxy のデフォルト実装に任せる

    func toggleFavorite() { content.toggleFavorite() }
}
