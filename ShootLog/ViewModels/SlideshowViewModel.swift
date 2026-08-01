import SwiftUI

// スライドショーモードのViewModel。自動再生タイマー・進捗管理を担当する
@Observable
@MainActor
final class SlideshowViewModel: ContentViewModelProxy {
    let content: ContentViewModel

    var isPlaying = true
    var interval: Double = 3.0
    var progress: Double = 0.0
    private var timerTask: Task<Void, Never>?

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
            // 0.2 秒ごとに進捗を更新する。切替直後の親View再評価を抑えつつ、
            // プログレス表示として十分な粒度を維持する（Combine 不使用）。
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { break }
                if self.isPlaying {
                    self.progress += 0.2 / self.interval
                    if self.progress >= 1.0 { self.advanceSlideshow() }
                }
            }
        }
    }

    // 再生・一時停止を切り替える（タイマーの開始・停止も内部で完結させる）
    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            restartTimer()
        } else {
            timerTask?.cancel()
        }
    }

    // 再生を停止する（View の onDisappear などから呼ぶ）
    func stopPlayback() {
        isPlaying = false
        timerTask?.cancel()
    }

    // 再生間隔を変更し、タイマーを新しい間隔で再起動する
    func setInterval(_ seconds: Double) {
        interval = seconds
        restartTimer()
    }

    // スライドショー表示開始時にタイマーを起動する（ViewのonAppearから呼ぶ）
    func startPlayback() {
        isPlaying = true
        restartTimer()
    }

    // 次の写真へ進む。末尾まで来たら先頭へ戻る。
    // お気に入りのみ表示が有効なときは visiblePhotos（絞り込み後）を基準にする。
    // 未フィルタの photos で判定すると、最後のお気に入り写真が一覧末尾でない場合に
    // selectNext() が絞り込み側の末尾でクランプされ、ループが止まってしまう
    func advanceSlideshow() {
        progress = 0
        let list = content.visiblePhotos
        guard !list.isEmpty else { return }
        guard let selectedPhoto = content.selectedPhoto,
              let index = list.firstIndex(where: { $0.id == selectedPhoto.id }) else {
            content.selectPhoto(list.first)
            return
        }
        if index + 1 < list.count {
            content.selectNext()
        } else {
            content.selectPhoto(list.first)
        }
    }
}
