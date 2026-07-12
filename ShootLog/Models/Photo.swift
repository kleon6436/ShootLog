import Foundation
import SwiftData

/// 写真1枚に対応するSwiftDataモデル
@Model
final class Photo {
    var id: UUID
    var fileURL: URL
    var shootingDate: Date
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var aperture: Double?       // F値
    var shutterSpeed: Double?   // 秒
    var iso: Int?
    var focalLength: Double?    // mm
    var colorMode: String?      // Sigma fp L 等のカラーモード名（例: "PowderBlue"）
    var isFavorite: Bool
    var note: String

    init(id: UUID = UUID(), fileURL: URL) {
        self.id = id
        self.fileURL = fileURL
        self.shootingDate = Date()
        self.isFavorite = false
        self.note = ""
    }
}
