import Foundation

// フォルダ内の画像ファイルURLをスキャンするリポジトリ（ステートレス）
enum PhotoRepository {

    struct ScanResult: Sendable {
        let urls: [URL]
        let snapshots: [URL: FileAttributesSnapshot]
    }

    // 対応している画像フォーマットの拡張子
    private static let supportedExtensions: Set<String> = [
        "nef", "dng", "arw", "cr3", "raf",
        "jpg", "jpeg",
        "heic", "tiff", "png"
    ]

    // フォルダ直下の対応画像URLと、スキャン時に取得した属性を返す。サブフォルダは再帰しない
    // ネットワークドライブ対応：必要な属性を列挙時にまとめて取得し、後続処理で再取得しない
    static func scanImageURLs(in folderURL: URL) throws -> ScanResult {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let filtered = contents.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }

        // ソート比較器の内部で resourceValues を呼ぶと O(n log n) 回の I/O になる。
        // 先にまとめてプリフェッチしてから辞書参照でソートする
        let snapshots = filtered.reduce(into: [URL: FileAttributesSnapshot]()) { dict, url in
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey
            ])
            dict[url] = FileAttributesSnapshot(
                size: values?.fileSize.map(Int64.init),
                modificationDate: values?.contentModificationDate,
                creationDate: values?.creationDate
            )
        }
        let sorted = filtered.sorted {
            (snapshots[$0]?.creationDate ?? .distantPast)
                < (snapshots[$1]?.creationDate ?? .distantPast)
        }
        return ScanResult(urls: sorted, snapshots: snapshots)
    }
}

struct FileAttributesSnapshot: Sendable, Equatable {
    let size: Int64?
    let modificationDate: Date?
    let creationDate: Date?
}
