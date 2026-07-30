import SwiftUI

// スライドショーモードのViewModel。自動再生タイマー・進捗管理を担当する
@Observable
@MainActor
final class SlideshowViewModel {
    let content: ContentViewModel

    var isPlaying = true
    var interval: Double = 3.0
    var progress: Double = 0.0
    var timerTask: Task<Void, Never>?

    init(content: ContentViewModel) {
        self.content = content
    }

    // MARK: - Content Delegation

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

    func switchToSidebar() { content.switchToSidebar() }
    func openFolder() { content.openFolder() }
    func openAnalysis() { content.openAnalysis() }
    func openInExternalApp(_ adapter: any ExternalAppProtocol) { content.openInExternalApp(adapter) }

    // 「前へ」ボタン用。進捗バーもリセットする
    func selectPrevious() {
        progress = 0
        content.selectPrevious()
    }

    // MARK: - Timer

    func restartTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            // 0.1 秒ごとに進捗を更新する（Combine 不使用）
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { break }
                if self.isPlaying {
                    self.progress += 0.1 / self.interval
                    if self.progress >= 1.0 { self.advanceSlideshow() }
                }
            }
        }
    }

    func advanceSlideshow() {
        progress = 0
        if content.selectedIndex + 1 < content.photos.count {
            content.selectNext()
        } else {
            // 最後まで来たら先頭に戻る
            content.selectPhoto(content.photos.first)
        }
    }
}
