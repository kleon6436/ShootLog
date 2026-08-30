import Foundation
import SwiftData

/// 非破壊編集情報。元ファイルは変更しない。
/// - `rotation`: 表示時（rotationEffect）・現像書き出し・超解像書き出しのいずれでも適用される。
/// - `cropRect`: 現像書き出し（`DevelopExporter`）と現像プレビューで焼き込まれ、トリミングモードの
///   オーバーレイ初期矩形にも使う。単体の超解像書き出し（`UpscaleExporter`）には**適用されない**。
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
