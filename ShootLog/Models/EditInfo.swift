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
    // トリミング矩形は4つのスカラー属性で保存する。`CGRect?` をそのまま持つと SwiftData の
    // 複合属性になるが、CGRect の Codable は unkeyed コンテナを使うため、macOS 27 の SwiftData では
    // 保存・読み出しの両方で "Composite Coder only supports Keyed Container" の fatalError になる。
    private var cropX: Double?
    private var cropY: Double?
    private var cropWidth: Double?
    private var cropHeight: Double?
    var createdAt: Date

    // nil = トリミングなし。正規化座標 0.0〜1.0。基準は「回転適用後に表示されている画像」の矩形
    // （ビューアペイン全体ではなく、レターボックスを除いた画像領域）。CropViewModel と同じ基準。
    var cropRect: CGRect? {
        get {
            guard let cropX, let cropY, let cropWidth, let cropHeight else { return nil }
            return CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        }
        set {
            cropX = newValue.map { Double($0.minX) }
            cropY = newValue.map { Double($0.minY) }
            cropWidth = newValue.map { Double($0.width) }
            cropHeight = newValue.map { Double($0.height) }
        }
    }

    init(photoID: UUID) {
        self.photoID = photoID
        self.rotation = 0
        self.createdAt = Date()
    }
}
