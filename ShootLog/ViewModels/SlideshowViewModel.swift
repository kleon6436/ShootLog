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

    // 前後1枚を先読みするTask。写真が切り替わるたびに前回分をキャンセルして張り替える。
    // キャンセルで打ち切れるのは HighResPrefetcher の待機中・未着手分までで、
    // 開始済みの1枚のデコードは完走する（ImageLoader 内部が Task.detached のため）
    private var prefetchTask: Task<Void, Never>?

    init(content: ContentViewModel) {
        self.content = content
        // 「一般」設定タブで指定された自動再生・再生間隔の既定値を読み込む。
        // bool(forKey:) は未設定時 false、double(forKey:) は 0 を返すため既定値へフォールバックする
        let defaults = UserDefaults.standard
        isPlaying = defaults.object(forKey: AppSettingsKeys.slideshowAutoplay) as? Bool
            ?? AppSettingsKeys.slideshowAutoplayDefault
        let storedInterval = defaults.double(forKey: AppSettingsKeys.slideshowInterval)
        interval = storedInterval > 0 ? storedInterval : AppSettingsKeys.slideshowIntervalDefault
    }

    // MARK: - Content Delegation

    // 単純な委譲は ContentViewModelProxy のデフォルト実装に任せる。
    // 写真送りの2つだけは進捗リセットと先読みが必要なため独自実装で上書きする

    // 「前へ」ボタン用。進捗バーもリセットする
    func selectPrevious() {
        progress = 0
        content.selectPrevious()
        prefetchNeighbors()
    }

    // メニューコマンド等からの「次へ」。SlideshowModeView の送りボタンと自動送りは
    // 末尾で先頭へループする advanceSlideshow() を使うが、デフォルト実装のままだと
    // 進捗リセットと先読みが漏れるため selectPrevious() と対称に上書きする
    func selectNext() {
        progress = 0
        content.selectNext()
        prefetchNeighbors()
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

    // 再生を停止する（View の onDisappear などから呼ぶ）。
    // isPlaying は「再生したいか」というユーザーの意思として保持したままにする：
    // ここで false へ落とすと、自動再生ONの設定でもモードへ戻った際に再生が始まらなくなる
    func stopPlayback() {
        timerTask?.cancel()
        prefetchTask?.cancel()
    }

    // 再生間隔を変更し、タイマーを新しい間隔で再起動する。
    // progress をリセットしないと、変更前の間隔で進んだ分の進捗が新しい間隔に
    // 引き継がれてしまい、切替タイミングが大きくズレるため 0 に戻す
    func setInterval(_ seconds: Double) {
        interval = seconds
        progress = 0
        restartTimer()
    }

    // 下部表示用の残り秒数（切り上げ）。progress は加算誤差で 1.0 をわずかに超える瞬間があるため 0 未満にならないようクランプする
    var remainingSeconds: Int {
        Int((max(0, 1.0 - progress) * interval).rounded(.up))
    }

    // スライドショー表示開始時にタイマーを起動する（ViewのonAppearから呼ぶ）。
    // 自動再生OFF設定や一時停止中は isPlaying を尊重してタイマーを起動しない
    func startPlayback() {
        if isPlaying { restartTimer() }
        // 自動再生OFFでも手動送りは行われるため、再生状態に関わらず先読みを開始する
        prefetchNeighbors()
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
        prefetchNeighbors()
    }

    // MARK: - Prefetch

    // 現在の選択写真の前後1枚の高解像度画像を先読みし、切替時のデコード待ちをなくす。
    // 先読みの実処理は HighResPrefetcher に集約し、ビューア（PhotoViewerView /
    // EditablePhotoView）と同じ挙動を共有する。
    //
    // スライドショーはViewから先読み対象を注入する経路を持たない（SlideshowModeView は
    // PhotoViewerView へ写真しか渡さない）ため、発火のみここで行う。
    // 「次」は advanceSlideshow が末尾で先頭へループするのに合わせて巻き戻す
    private func prefetchNeighbors() {
        let list = content.visiblePhotos
        let index = list.firstIndex { $0.id == content.selectedPhoto?.id }
        // MainActor 上で URL（Sendable）だけを取り出してから detached タスクへ渡す
        let urls = HighResPrefetcher.neighborURLs(in: list, around: index, wrapsAround: true)
        guard !urls.isEmpty else { return }

        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .utility) {
            await HighResPrefetcher.prefetch(urls: urls)
        }
    }
}
