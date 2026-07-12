import Foundation

// フルスクリーンモード専用のViewModel。独自状態は持たず ContentViewModel への薄いプロキシに徹する
@Observable
@MainActor
final class FullscreenViewModel {
    let content: ContentViewModel

    init(content: ContentViewModel) {
        self.content = content
    }

    var selectedPhoto: Photo? { content.selectedPhoto }
    var currentEditInfo: EditInfo? { content.currentEditInfo }
    var selectedIndex: Int { content.selectedIndex }
    var photos: [Photo] { content.photos }

    func selectNext() { content.selectNext() }
    func selectPrevious() { content.selectPrevious() }
    func toggleFavorite() { content.toggleFavorite() }
    func switchToSidebar() { content.switchToSidebar() }
}
