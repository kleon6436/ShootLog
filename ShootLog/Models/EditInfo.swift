import Foundation
import SwiftData

/// 非破壊編集情報。元ファイルは変更しない。rotationは表示時（rotationEffect）と
/// 超解像・現像書き出し時に適用される。cropRectは現像書き出し（DevelopExporter）で
/// 焼き込まれ、トリミングモードのオーバーレイ初期矩形にも使う。ライブプレビューは未対応。
@Model
final class EditInfo {
    var photoID: UUID
    var rotation: Int           // 0 / 90 / 180 / 270
    // nil = トリミングなし。正規化座標 0.0〜1.0。基準は「回転適用後に表示されている画像」の矩形
    // （ビューアペイン全体ではなく、レターボックスを除いた画像領域）。CropViewModel と同じ基準。
    var cropRect: CGRect?
    var createdAt: Date

    init(photoID: UUID) {
        self.photoID = photoID
        self.rotation = 0
        self.createdAt = Date()
    }
}
