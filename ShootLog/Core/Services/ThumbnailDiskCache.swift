import CryptoKit
import Foundation
import ImageIO

// サムネイルのディスクキャッシュ（PNG）。メモリキャッシュとスロット制御は ImageLoader 側が持つ
enum ThumbnailDiskCache {

    // URL の SHA256 ハッシュをファイル名にしたディスクキャッシュ URL
    static func fileURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("png")
    }

    static func write(cgImage: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    // ~/Library/Caches/com.shootlog.app/thumbnails-v4/
    // （v4=埋め込みプレビューが小さすぎる場合のフルデコードフォールバックを追加、v3までのぼやけキャッシュを無効化）
    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.shootlog.app/thumbnails-v4", isDirectory: true)
    }()

    // キャッシュディレクトリ内のファイルをすべて削除する。
    // 部分的な削除失敗は致命的ではないため try? で無視し、次回表示時に再生成させる
    static func removeAllFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
