import SwiftUI
import AppKit

// 写真グリッドセルのサムネイル読み込みを担うViewModel
@Observable
@MainActor
final class PhotoThumbnailViewModel {
    var thumbnail: NSImage?

    func load(url: URL) async {
        thumbnail = await ImageLoader.shared.thumbnail(for: url)
    }
}
