import Foundation
import SwiftData

/// 「なぜうまく撮れたか」を振り返るための成功要因タグ。
/// raw valueは永続化形式のため安定したASCIIとし、表示ラベルは`displayName`で分離する。
/// 宣言順（`allCases`順）がUIのボタン表示順・集計表示順を決定する。
enum SuccessTagCategory: String, CaseIterable, Codable {
    case light
    case composition
    case timing
    case focus
    case editing

    var displayName: String {
        switch self {
        case .light: String(localized: "photo.tag.light")
        case .composition: String(localized: "photo.tag.composition")
        case .timing: String(localized: "photo.tag.timing")
        case .focus: String(localized: "photo.tag.focus")
        case .editing: String(localized: "photo.tag.editing")
        }
    }
}

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
    var pixelWidth: Int?
    var pixelHeight: Int?
    var fileSizeBytes: Int64?
    var isFavorite: Bool
    var note: String
    var exifFetchedAt: Date?    // EXIF取得済み判定用フラグ（cameraModel等の欠損に依存しない）
    // 軽量マイグレーションのため宣言時デフォルト値が必須（既存行にはinitが走らない）
    var successTagRawValues: [String] = []
    var asShotTemperatureKelvin: Double? = nil
    var asShotTint: Double? = nil
    var asShotWhiteBalanceIsEstimated: Bool? = nil
    var asShotWhiteBalanceFetchedAt: Date? = nil
    var phAssetLocalIdentifier: String? = nil

    /// 成功要因タグの読み書きアクセサ。未知のraw valueは無視し、他のタグの読み取りに影響させない
    var successTags: [SuccessTagCategory] {
        get { successTagRawValues.compactMap(SuccessTagCategory.init(rawValue:)) }
        set { successTagRawValues = newValue.map(\.rawValue) }
    }

    init(id: UUID = UUID(), fileURL: URL) {
        self.id = id
        self.fileURL = fileURL
        self.shootingDate = Date()
        self.isFavorite = false
        self.note = ""
    }

    convenience init(id: UUID = UUID(), fileURL: URL, phAssetLocalIdentifier: String) {
        self.init(id: id, fileURL: fileURL)
        self.phAssetLocalIdentifier = phAssetLocalIdentifier
    }
}
