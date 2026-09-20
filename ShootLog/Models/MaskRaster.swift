import Foundation
import SwiftData

/// AI マスク（被写体・人物）のラスタを保持する子エンティティ。
///
/// `DevelopSettings.parametersData`（JSON blob）内の `AIMaskReference.rasterID` と `id` が一致する。
/// blob 側は参照 ID のみを持ち、実データ（PNG）をここへ分離することで、`DevelopSettings.parameters`
/// の毎アクセス JSON デコードと 500ms デバウンスの再エンコードから重いバイナリを外す。
/// ディスクキャッシュではないため、設定画面の「ディスクキャッシュを削除」の対象外。
@Model
final class MaskRaster {
    /// `AIMaskReference.rasterID` と一致する ID。
    var id: UUID = UUID()
    /// 長辺 `longEdge` のグレースケール PNG データ。
    var pngData: Data = Data()
    /// PNG の実際の長辺ピクセル数。描画時の拡大係数の計算に使う。
    /// `AIMaskReference.bakedLongEdge` は UI 表示・再生成要否判定のヒントに過ぎず、
    /// 食い違う場合はこちらを正とする。
    var longEdge: Int = 0
    var createdAt: Date = Date.now

    /// 親 `DevelopSettings` への逆関係。`DevelopSettings.maskRasters` の
    /// `@Relationship(deleteRule: .cascade)` と対になり、親の削除で連動削除される。
    var developSettings: DevelopSettings?

    init(id: UUID, pngData: Data, longEdge: Int) {
        self.id = id
        self.pngData = pngData
        self.longEdge = longEdge
        self.createdAt = .now
    }
}
