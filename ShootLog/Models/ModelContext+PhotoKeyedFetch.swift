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
}
