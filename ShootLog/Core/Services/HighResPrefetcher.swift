import Foundation

// 選択中写真の前後数枚を先読みしてプレビュープロキシのキャッシュへ載せるための共通処理。
// ビューア（PhotoViewerView / EditablePhotoView）とスライドショー（SlideshowViewModel）が
// 同じ挙動を共有できるよう、先読みの実装をここ1か所に集約する
enum HighResPrefetcher {

    // 先読みを始めるまでの待機時間。表示中写真のデコードを優先させると同時に、
    // 写真を連続で送った際に通り過ぎた写真の先読みを（開始前に）打ち切るデバウンスとして働く
    private static let startDelay = Duration.milliseconds(250)

    // 先読みする前後枚数。ローカルは連続送りでも先行できるよう広め、
    // ネットワークは同時取得を絞る `ImageLoader` の方針に合わせて狭くする
    private static let localRadius = 3
    private static let networkRadius = 1

    // ボリューム種別（ネットワーク/ローカル）の判定は resourceValues の syscall を伴うため、
    // ボリュームルート単位でキャッシュする（`neighborURLs` は body 再評価のたびに呼ばれうる）
    @MainActor private static var networkVolumeCache: [String: Bool] = [:]

    @MainActor
    private static func prefetchRadius(for url: URL) -> Int {
        let volumeKey = ((try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? url).path
        let isNetwork: Bool
        if let cached = networkVolumeCache[volumeKey] {
            isNetwork = cached
        } else {
            isNetwork = url.isOnNetworkVolume
            networkVolumeCache[volumeKey] = isNetwork
        }
        return isNetwork ? networkRadius : localRadius
    }

    // 指定URLのプレビュープロキシをキャッシュへ載せる。戻り値は破棄する（View更新はトリガーしない）。
    // 固定解像度のため、本表示と同じキャッシュキーへ載せられる。
    //
    // キャンセルで打ち切れるのは「まだ開始していないURL」までである点に注意する。
    // ImageLoader.proxyImage 内部のデコードは Task.detached で走りキャンセルを継承しないため、
    // 開始済みの1枚分は最後まで実行される
    static func prefetch(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        try? await Task.sleep(for: startDelay)
        for url in urls {
            guard !Task.isCancelled else { return }
            _ = await ImageLoader.shared.proxyImage(for: url)
        }
    }

    // 選択中写真の前後数枚のURL。進行方向が優先されるよう距離ごとに「次」を先に並べる
    // （next, prev, next+1, prev-1, …）。先読み枚数はボリューム種別で決まる。
    // 先頭・末尾では存在する側だけを返し、「次」方向は wrapsAround が true のときのみ
    // 先頭へ巻き戻す（スライドショーの自動送りがループするため）。「前」方向は巻き戻さない。
    @MainActor
    static func neighborURLs(
        in photos: [Photo],
        around index: Int?,
        wrapsAround: Bool = false
    ) -> [URL] {
        guard let index, photos.count > 1, photos.indices.contains(index) else { return [] }
        let radius = min(prefetchRadius(for: photos[index].fileURL), photos.count - 1)
        var urls: [URL] = []
        var seen: Set<Int> = [index]
        for distance in 1...radius {
            let forward = index + distance
            if forward < photos.count {
                appendIfNew(forward, from: photos, into: &urls, seen: &seen)
            } else if wrapsAround {
                appendIfNew(forward % photos.count, from: photos, into: &urls, seen: &seen)
            }
            let backward = index - distance
            if backward >= 0 {
                appendIfNew(backward, from: photos, into: &urls, seen: &seen)
            }
        }
        return urls
    }

    @MainActor
    private static func appendIfNew(
        _ photoIndex: Int,
        from photos: [Photo],
        into urls: inout [URL],
        seen: inout Set<Int>
    ) {
        guard seen.insert(photoIndex).inserted else { return }
        urls.append(photos[photoIndex].fileURL)
    }
}
