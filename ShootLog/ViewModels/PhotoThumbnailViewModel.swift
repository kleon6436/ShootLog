import SwiftUI
import AppKit

// 写真グリッドセルのサムネイル読み込みを担うViewModel
@Observable
@MainActor
final class PhotoThumbnailViewModel {
    var thumbnail: NSImage?

    func load(photo: Photo) async {
        if let localIdentifier = photo.phAssetLocalIdentifier {
            thumbnail = await PhotosLibraryThumbnailProvider.shared.thumbnail(
                forLocalIdentifier: localIdentifier,
                targetSize: CGSize(width: 480, height: 480)
            )
        } else {
            thumbnail = await ImageLoader.shared.thumbnail(for: photo.fileURL)
        }
    }
}
