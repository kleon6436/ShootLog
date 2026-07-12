import Foundation
import SwiftData

/// 非破壊編集情報。元ファイルは変更せず、表示・エクスポート時のみ適用する
@Model
final class EditInfo {
    var photoID: UUID
    var rotation: Int           // 0 / 90 / 180 / 270
    var cropRect: CGRect?       // nil = トリミングなし（正規化座標 0.0〜1.0）
    var createdAt: Date

    init(photoID: UUID) {
        self.photoID = photoID
        self.rotation = 0
        self.createdAt = Date()
    }
}
