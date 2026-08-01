import SwiftUI

// スライドショーモードのViewModel。自動再生タイマー・進捗管理を担当する
@Observable
@MainActor
final class SlideshowViewModel: ContentViewModelProxy {
    let content: ContentViewModel

    var isPlaying = true
    var interval: Double = 3.0
    var progress: Double = 0.0
    var timerTask: Task<Void, Never>?

    init(content: ContentViewModel) {
        self.content = content
    }

    // MARK: - Content Delegation

    // 単純な委譲は ContentViewModelProxy のデフォルト実装に任せる。
    // selectPrevious() のみ進捗リセットが必要なため独自実装で上書きする

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
