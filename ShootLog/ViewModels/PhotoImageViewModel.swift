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
    func load(photo: Photo?) async {
        // 前の写真の残像をクリアしてから新しい写真をロード
        thumbnail = nil
        highRes = nil
        isLoadingHighRes = false
        guard let photo else { return }
        let loadedThumbnail = await ImageLoader.shared.thumbnail(for: photo.fileURL)
        // サムネイル取得中に写真が切り替わっていたら代入も高解像度ロードもスキップする
        // （旧タスクが後から再開して前の写真のサムネイルを上書きするのを防ぐ）
        guard !Task.isCancelled else { return }
        thumbnail = loadedThumbnail
        isLoadingHighRes = true
        let loadedHighRes = await ImageLoader.shared.highResImage(for: photo.fileURL)
        // 高解像度画像取得中に写真が切り替わっていたら代入をスキップする（stale image代入防止）。
        // isLoadingHighRes の解除もこのガードより後に行う。先に解除すると
        // 新しい写真のロード中スピナーを旧タスクが消してしまう
        guard !Task.isCancelled else { return }
        isLoadingHighRes = false
        highRes = loadedHighRes
    }
}
