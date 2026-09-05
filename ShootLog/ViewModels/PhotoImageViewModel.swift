import SwiftUI
import AppKit

// PhotoViewerView / EditablePhotoView共通のサムネイル→プレビュープロキシ2段階ロードを担うViewModel
// Step1: サムネイルを即時表示 → Step2: 固定解像度プロキシに差し替え
@Observable
@MainActor
final class PhotoImageViewModel {
    var thumbnail: NSImage?
    var highRes: NSImage?
    var isLoadingHighRes = false

    // 指定写真のサムネイル→プレビュープロキシを順に読み込む
    //
    // displaySize には表示領域のビューサイズ（pt）を渡す。画面スケールを掛けたピクセル数が
    // 固定プロキシの解像度を明確に上回る場合だけ、より大きいダウンサンプル画像を追加で要求する。
    // nil の場合は既定の目標サイズを使う。
    // ズーム時は「ズーム後の実効表示サイズ（ビューサイズ × ズーム倍率）」を渡す。追加要求の目標値は
    // ImageLoader 側で512px刻みに量子化されるが、それでも再デコードは発生するため、
    // 呼び出し側はズーム操作完了時のみ再ロードするデバウンスを行うこと。
    //
    // useFullResolution に true を渡すと displaySize を無視してフルサイズデコードへフォールバックする
    // （最大ズーム時に等倍以上で表示する場合に使う）
    func load(photo: Photo?, displaySize: CGSize? = nil, useFullResolution: Bool = false) async {
        // 前の写真の残像をクリアしてから新しい写真をロード
        thumbnail = nil
        highRes = nil
        isLoadingHighRes = false
        guard let photo else { return }
        let fileURL = photo.fileURL

        if let localIdentifier = photo.phAssetLocalIdentifier {
            thumbnail = await PhotosLibraryThumbnailProvider.shared.thumbnail(
                forLocalIdentifier: localIdentifier,
                targetSize: CGSize(width: 480, height: 480)
            )
            guard !Task.isCancelled else { return }
            isLoadingHighRes = true
            await PhotosLibraryAssetExporter.shared.ensureExported(
                localIdentifier: localIdentifier,
                fileURL: fileURL
            )
            guard !Task.isCancelled else { return }
        } else {
            let loadedThumbnail = await ImageLoader.shared.thumbnail(for: fileURL)
            // サムネイル取得中に写真が切り替わっていたら代入も高解像度ロードもスキップする
            // （旧タスクが後から再開して前の写真のサムネイルを上書きするのを防ぐ）
            guard !Task.isCancelled else { return }
            thumbnail = loadedThumbnail
            isLoadingHighRes = true
        }

        if useFullResolution {
            let loadedHighRes = await ImageLoader.shared.highResImage(
                for: fileURL,
                targetMaxPixelSize: ImageLoader.fullSizePixelTarget
            )
            guard !Task.isCancelled else { return }
            highRes = loadedHighRes
        } else {
            let proxy = await ImageLoader.shared.proxyImage(for: fileURL)
            guard !Task.isCancelled else { return }
            if let proxy {
                highRes = proxy
            }

            let displayNeed = Self.targetMaxPixelSize(for: displaySize)
            let proxyEdge = CGFloat(PreviewCacheStore.shared.proxyLongEdge)
            if displayNeed > proxyEdge * 1.1 {
                let bigger = await ImageLoader.shared.highResImage(
                    for: fileURL,
                    targetMaxPixelSize: displayNeed
                )
                guard !Task.isCancelled else { return }
                if let bigger {
                    highRes = bigger
                }
            }
        }
        // 高解像度画像取得中に写真が切り替わっていたら代入をスキップする（stale image代入防止）。
        // isLoadingHighRes の解除もこのガードより後に行う。先に解除すると
        // 新しい写真のロード中スピナーを旧タスクが消してしまう
        guard !Task.isCancelled else { return }
        isLoadingHighRes = false
    }

    // 表示領域サイズ（pt）を画面スケール込みのピクセル数へ変換する。
    static func targetMaxPixelSize(for displaySize: CGSize?) -> CGFloat {
        guard let displaySize, displaySize.width > 0, displaySize.height > 0 else {
            return ImageLoader.defaultHighResMaxPixelSize
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return max(displaySize.width, displaySize.height) * scale
    }
}
