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
        thumbnail = await ImageLoader.shared.thumbnail(for: photo.fileURL)
        // サムネイル取得後に写真が切り替わっていたら高解像度ロードをスキップする
        guard !Task.isCancelled else { return }
        isLoadingHighRes = true
        highRes = await ImageLoader.shared.highResImage(for: photo.fileURL)
        isLoadingHighRes = false
    }
}
