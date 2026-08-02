import Foundation

// 選択中写真の前後1枚を先読みしてImageLoaderのキャッシュへ載せるための共通処理。
// ビューア（PhotoViewerView / EditablePhotoView）とスライドショー（SlideshowViewModel）が
// 同じ挙動を共有できるよう、先読みの実装をここ1か所に集約する
enum HighResPrefetcher {

    // 先読みを始めるまでの待機時間。表示中写真のデコードを優先させると同時に、
    // 写真を連続で送った際に通り過ぎた写真の先読みを（開始前に）打ち切るデバウンスとして働く
    private static let startDelay = Duration.milliseconds(250)

    // 指定URLの高解像度画像をキャッシュへ載せる。戻り値は破棄する（View更新はトリガーしない）。
    // targetMaxPixelSize は既定値のまま呼び、本表示と同じキャッシュキーへ載せる。
    //
    // キャンセルで打ち切れるのは「まだ開始していないURL」までである点に注意する。
    // ImageLoader.highResImage 内部のデコードは Task.detached で走りキャンセルを継承しないため、
    // 開始済みの1枚分は最後まで実行される
    static func prefetch(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        try? await Task.sleep(for: startDelay)
        for url in urls {
            guard !Task.isCancelled else { return }
            _ = await ImageLoader.shared.highResImage(for: url)
        }
    }

    // 選択中写真の前後1枚のURL。進行方向が優先されるよう「次」を先に並べる。
    // 先頭・末尾では存在する側だけを返し、wrapsAround が true のときのみ
    // 末尾の「次」を先頭へ巻き戻す（スライドショーの自動送りがループするため）
    @MainActor
    static func neighborURLs(
        in photos: [Photo],
        around index: Int?,
        wrapsAround: Bool = false
    ) -> [URL] {
        guard let index, photos.count > 1, photos.indices.contains(index) else { return [] }
        var urls: [URL] = []
        if index + 1 < photos.count {
            urls.append(photos[index + 1].fileURL)
        } else if wrapsAround {
            urls.append(photos[0].fileURL)
        }
        if index > 0 {
            urls.append(photos[index - 1].fileURL)
        }
        return urls
    }
}
