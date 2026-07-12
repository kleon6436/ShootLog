import Foundation

// フォルダ内の画像ファイルURLをスキャンするリポジトリ（ステートレス）
enum PhotoRepository {

    // 対応している画像フォーマットの拡張子
    private static let supportedExtensions: Set<String> = [
        "nef", "dng", "arw", "cr3", "raf",
        "jpg", "jpeg",
        "heic", "tiff", "png"
    ]

    // フォルダ直下の対応画像URLを返す。サブフォルダは再帰しない
    // ネットワークドライブ対応：日付をソート前に一括取得してファイルシステム呼び出しを最小化する
    static func scanImageURLs(in folderURL: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let filtered = contents.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }

        // ソート比較器の内部で resourceValues を呼ぶと O(n log n) 回の I/O になる。
        // 先にまとめてプリフェッチしてから辞書参照でソートする
        let dates = filtered.reduce(into: [URL: Date]()) { dict, url in
            dict[url] = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        }
        return filtered.sorted { dates[$0, default: .distantPast] < dates[$1, default: .distantPast] }
    }
}
