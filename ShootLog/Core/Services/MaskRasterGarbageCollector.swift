import Foundation
import SwiftData

/// `AIMaskReference.rasterID`（JSON blob 内）から到達できなくなった `MaskRaster` を掃除する。
///
/// `MaskRaster` と `AIMaskReference` の間に外部キー制約は無く、`deleteRule: .cascade` が効くのは
/// `DevelopSettings` 自体が削除されたときだけなので、レイヤー単体削除やプリセット/ペーストの
/// 1 段 Undo で容易に孤児が生まれる。即時削除ではなく到達可能性ベースの GC で扱うことで、
/// 削除直後の Undo で参照先が消えている状態を避け、削除コードを各操作へ散らさずに済む（§3.2）。
enum MaskRasterGarbageCollector {

    /// 全 `DevelopSettings` を走査し、blob から到達できない `MaskRaster` を削除する。
    /// 全件 fetch を伴うため、起動時にアプリ全体で 1 回だけ呼ぶ。
    /// - Returns: 削除した `MaskRaster` の件数。
    @discardableResult
    static func collectAll(in context: ModelContext) -> Int {
        let allSettings = (try? context.fetch(FetchDescriptor<DevelopSettings>())) ?? []
        let deletedCount = allSettings.reduce(0) { $0 + collect(for: $1, in: context) }
        if deletedCount > 0 {
            try? context.save()
        }
        return deletedCount
    }

    /// 写真 1 枚分だけを対象にした軽量版。写真切り替え時に「離れる写真」へ対して呼ぶ。
    /// フェッチは `#Predicate` での UUID フィルタが不安定なケースに備え、
    /// `loadDevelopSettings` と同じ「全件 fetch して first(where:)」パターンを踏襲する。
    /// - Returns: 削除した `MaskRaster` の件数。
    @discardableResult
    static func collect(forPhotoID photoID: UUID, in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<DevelopSettings>())) ?? []
        guard let settings = all.first(where: { $0.photoID == photoID }) else { return 0 }
        let deletedCount = collect(for: settings, in: context)
        if deletedCount > 0 {
            try? context.save()
        }
        return deletedCount
    }

    /// 指定した `DevelopSettings` の `maskRasters` のうち、その blob から到達できないものを削除する。
    /// 保存は呼び出し側が行う。
    /// - Returns: 削除した `MaskRaster` の件数。
    @discardableResult
    static func collect(for settings: DevelopSettings, in context: ModelContext) -> Int {
        let referencedIDs = Set(settings.parameters.masks.compactMap { layer -> UUID? in
            guard case .ai(let reference) = layer.source else { return nil }
            return reference.rasterID
        })
        let orphans = settings.maskRasters.filter { !referencedIDs.contains($0.id) }
        for orphan in orphans {
            context.delete(orphan)
        }
        return orphans.count
    }
}
