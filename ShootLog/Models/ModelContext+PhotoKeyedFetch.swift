import Foundation
import SwiftData

// 写真 ID で EditInfo / DevelopSettings を1件だけ引く。
// 以前は「#Predicate の UUID フィルタが不安定」として全件 fetch + first(where:) にしていたが、
// 写真を選ぶたびに全行を実体化するため、行数に比例して MainActor を占有していた（1万行規模で約100ms）。
// 不安定だった原因は述語クロージャの中で `photo.id` のようにモデルのプロパティを参照していたことで、
// 値を引数（ローカルの let）として捕捉すれば SQL の等値比較に変換される。
// インメモリ・ディスク上のストアの両方で ModelContextPhotoKeyedFetchTests が確かめている
extension ModelContext {
    func editInfo(forPhotoID photoID: UUID) -> EditInfo? {
        var descriptor = FetchDescriptor<EditInfo>(predicate: #Predicate { $0.photoID == photoID })
        descriptor.fetchLimit = 1
        return (try? fetch(descriptor))?.first
    }

    func developSettings(forPhotoID photoID: UUID) -> DevelopSettings? {
        var descriptor = FetchDescriptor<DevelopSettings>(predicate: #Predicate { $0.photoID == photoID })
        descriptor.fetchLimit = 1
        return (try? fetch(descriptor))?.first
    }

    // SQLite の 1 文あたりのバインド変数の上限に当たらないよう、IN 句の要素数を区切る
    static let photoURLFetchChunkSize = 500

    /// 指定した URL の Photo だけを返す。表示フォルダの写真を引くために使い、別フォルダの写真は実体化しない。
    /// URL 型の述語は PhotoURLPredicateGateTests がインメモリ・ディスク上のストアで確かめている
    func photos(withFileURLs urls: [URL]) throws -> [Photo] {
        var result: [Photo] = []
        result.reserveCapacity(urls.count)
        var start = urls.startIndex
        while start < urls.endIndex {
            let end = min(start + Self.photoURLFetchChunkSize, urls.endIndex)
            let chunk = Array(urls[start..<end])
            let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { chunk.contains($0.fileURL) })
            result.append(contentsOf: try fetch(descriptor))
            start = end
        }
        return result
    }
}
