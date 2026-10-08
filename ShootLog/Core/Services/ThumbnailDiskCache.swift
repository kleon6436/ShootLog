import CryptoKit
import Foundation
import ImageIO

// サムネイルのディスクキャッシュ（PNG）。メモリキャッシュとスロット制御は ImageLoader 側が持つ
enum ThumbnailDiskCache {

    // URL・更新日時・ファイルサイズの SHA256 ハッシュをファイル名にしたディスクキャッシュ URL。
    // 更新日時とサイズをキーへ含めることで、同じパスのまま上書きされた原本は別キーになり、
    // 古いサムネイルを表示し続けない（旧キーのファイルは孤児として残るが、キャッシュ削除で消える）。
    //
    // modificationDate / fileSize を渡せば（FileAttributesSnapshot 等）そのまま使い、
    // どちらかが nil の場合だけファイル属性を個別に取得する。
    // 属性取得はファイルI/Oのため、@MainActor 上から呼ばないこと（ImageLoader.thumbnail は非隔離の async で呼ぶ）。
    static func fileURL(for url: URL, modificationDate: Date? = nil, fileSize: Int64? = nil) -> URL {
        let fallbackAttributes = modificationDate == nil || fileSize == nil
            ? try? FileManager.default.attributesOfItem(atPath: url.path)
            : nil
        let resolvedModificationDate = modificationDate?.timeIntervalSinceReferenceDate
            ?? (fallbackAttributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
            ?? 0
        let resolvedFileSize = fileSize
            ?? (fallbackAttributes?[.size] as? NSNumber)?.int64Value
            ?? 0
        let source = "\(url.absoluteString)|\(resolvedModificationDate)|\(resolvedFileSize)"
        let hash = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("png")
    }

    // 一時ファイルへ書き出してから置換する（原子的書き込み）。
    // 書き込み途中のクラッシュや同一キーの並行書き込みで、壊れた PNG を最終パスへ残さない
    static func write(cgImage: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = ImageFileCache.write(cgImage, type: "public.png" as CFString, to: url)
    }

    // ~/Library/Caches/com.shootlog.app/thumbnails-v5/
    // （v4=埋め込みプレビューが小さすぎる場合のフルデコードフォールバックを追加、v3までのぼやけキャッシュを無効化。
    //   v5=キーへ更新日時・ファイルサイズを追加し、上書きされた原本の古いサムネイルを無効化）
    static let directory: URL = {
        cachesRoot.appendingPathComponent("thumbnails-v5", isDirectory: true)
    }()

    // キー形式が変わって参照されなくなった旧世代のディレクトリ
    static let legacyDirectories: [URL] = {
        ["thumbnails-v4"].map { cachesRoot.appendingPathComponent($0, isDirectory: true) }
    }()

    private static var cachesRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.shootlog.app", isDirectory: true)
    }

    // キャッシュディレクトリ内のファイルをすべて削除する（旧世代ディレクトリも併せて削除する）。
    // 部分的な削除失敗は致命的ではないため try? で無視し、次回表示時に再生成させる
    static func removeAllFiles() {
        removeLegacyDirectories()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // 旧世代のサムネイルディレクトリを丸ごと削除する。存在しなければ何もしない
    static func removeLegacyDirectories() {
        for legacyDirectory in legacyDirectories {
            try? FileManager.default.removeItem(at: legacyDirectory)
        }
    }
}
