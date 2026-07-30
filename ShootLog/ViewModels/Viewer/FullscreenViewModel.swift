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

    // ツールバー（Pickerの選択）から直接切り替えるためget/set両方必要
    var currentModeID: String {
        get { content.currentModeID }
        set { content.currentModeID = newValue }
    }

    // ツールバーのトグルとも同期する必要があるためContentViewModelを単一の真実源とし委譲する
    var showFavoritesOnly: Bool {
        get { content.showFavoritesOnly }
        set { content.showFavoritesOnly = newValue }
    }

    func selectNext() { content.selectNext() }
    func selectPrevious() { content.selectPrevious() }
    func toggleFavorite() { content.toggleFavorite() }
    func switchToSidebar() { content.switchToSidebar() }
    func openFolder() { content.openFolder() }
    func openAnalysis() { content.openAnalysis() }
    func openInExternalApp(_ adapter: any ExternalAppProtocol) { content.openInExternalApp(adapter) }
}
