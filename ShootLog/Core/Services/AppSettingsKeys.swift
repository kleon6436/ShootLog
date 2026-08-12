import Foundation

// 「一般」設定タブがUserDefaultsへ保存するキーと既定値の一元管理。
// 既存の "sidebarWidth" などと衝突しないよう generalSettings. の名前空間プレフィックスを付ける。
// UserDefaults.integer(forKey:) / double(forKey:) は未設定時に 0 を返すため、
// 読み込み側では必ず既定値へのフォールバックを入れること
enum AppSettingsKeys {
    static let defaultViewModeID = "generalSettings.defaultViewModeID"
    static let defaultFavoritesOnly = "generalSettings.defaultFavoritesOnly"
    static let defaultInspectorVisible = "generalSettings.defaultInspectorVisible"
    static let slideshowAutoplay = "generalSettings.slideshowAutoplay"
    static let slideshowInterval = "generalSettings.slideshowInterval"
    static let thumbnailQuality = "generalSettings.thumbnailQuality" // ThumbnailQuality の rawValue(Int)
    static let networkConcurrency = "generalSettings.networkConcurrency"
    static let folderHistoryLimit = "generalSettings.folderHistoryLimit"

    static let defaultViewModeIDDefault = "sidebar"
    static let defaultFavoritesOnlyDefault = false
    static let defaultInspectorVisibleDefault = false
    static let slideshowAutoplayDefault = true
    static let slideshowIntervalDefault = 3.0
    static let networkConcurrencyDefault = 4
    static let folderHistoryLimitDefault = 10
}

// サムネイル画質プリセット。rawValue がそのまま最大ピクセルサイズを表し、UserDefaultsへ保存される
enum ThumbnailQuality: Int, CaseIterable, Identifiable {
    case small = 512
    case standard = 768
    case high = 1024

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .small: String(localized: "settings.thumbnailQuality.small")
        case .standard: String(localized: "settings.thumbnailQuality.standard")
        case .high: String(localized: "settings.thumbnailQuality.high")
        }
    }
}
