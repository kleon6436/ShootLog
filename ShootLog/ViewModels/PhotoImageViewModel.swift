import SwiftUI
import AppKit

// PhotoViewerView / EditablePhotoView共通のサムネイル→高解像度2段階ロードを担うViewModel
// Step1: サムネイル(768px)を即時表示 → Step2: フルサイズ画像に差し替え
@Observable
@MainActor
final class PhotoImageViewModel {
    var thumbnail: NSImage?
    var highRes: NSImage?
    var isLoadingHighRes = false

    // 指定写真のサムネイル→高解像度画像を順に読み込む
    //
    // displaySize には表示領域のビューサイズ（pt）を渡す。画面スケールを掛けたピクセル数を
    // 目標解像度として ImageLoader に渡し、表示に必要な分だけデコードさせる。
    // nil の場合は既定の目標サイズを使う。
    // ズーム時は「ズーム後の実効表示サイズ（ビューサイズ × ズーム倍率）」を渡す。目標サイズは
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
        let targetMaxPixelSize = useFullResolution
            ? ImageLoader.fullSizePixelTarget
            : Self.targetMaxPixelSize(for: displaySize)
        let loadedThumbnail = await ImageLoader.shared.thumbnail(for: photo.fileURL)
        // サムネイル取得中に写真が切り替わっていたら代入も高解像度ロードもスキップする
        // （旧タスクが後から再開して前の写真のサムネイルを上書きするのを防ぐ）
        guard !Task.isCancelled else { return }
        thumbnail = loadedThumbnail
        isLoadingHighRes = true
        let loadedHighRes = await ImageLoader.shared.highResImage(
            for: photo.fileURL,
            targetMaxPixelSize: targetMaxPixelSize
        )
        // 高解像度画像取得中に写真が切り替わっていたら代入をスキップする（stale image代入防止）。
        // isLoadingHighRes の解除もこのガードより後に行う。先に解除すると
        // 新しい写真のロード中スピナーを旧タスクが消してしまう
        guard !Task.isCancelled else { return }
        isLoadingHighRes = false
        highRes = loadedHighRes
    }

    // 表示領域サイズ（pt）を画面スケール込みのピクセル数へ変換する。
    // 先読み(prefetch)から ImageLoader.highResImage を直接呼ぶ場合も、本表示と同じキャッシュ
    // エントリに載せるためこの変換を通した値を targetMaxPixelSize へ渡すこと
    static func targetMaxPixelSize(for displaySize: CGSize?) -> CGFloat {
        guard let displaySize, displaySize.width > 0, displaySize.height > 0 else {
            return ImageLoader.defaultHighResMaxPixelSize
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return max(displaySize.width, displaySize.height) * scale
    }
}
