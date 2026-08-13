import Foundation
import SwiftData

/// 非破壊編集情報。元ファイルは変更しない。rotationは表示時（rotationEffect）と
/// 超解像書き出し時に適用される。cropRectは現在CropOverlayViewの初期矩形としてのみ
/// 使用され、表示にも書き出しにも適用されていない
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
