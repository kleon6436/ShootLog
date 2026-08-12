import Foundation

/// アプリ全体で使用するエラー定義
enum ShootLogError: LocalizedError {
    case exifReadFailed
    case unsupportedFormat(extension: String)
    case folderAccessDenied
    case bookmarkRestorationFailed
    case applicationInfoUnavailable(name: String)
    case duplicateIntegrationApp(name: String)
    case settingsSaveFailed
    case photoDataSaveFailed

    var errorDescription: String? {
        switch self {
        case .exifReadFailed:
            return String(localized: "error.exifReadFailed")
        case .unsupportedFormat(let ext):
            return String(localized: "error.unsupportedFormat \(ext)")
        case .folderAccessDenied:
            return String(localized: "error.folderAccessDenied")
        case .bookmarkRestorationFailed:
            return String(localized: "error.bookmarkRestorationFailed")
        case .applicationInfoUnavailable(let name):
            return String(localized: "error.applicationInfoUnavailable \(name)")
        case .duplicateIntegrationApp(let name):
            return String(localized: "error.duplicateIntegrationApp \(name)")
        case .settingsSaveFailed:
            return String(localized: "error.settingsSaveFailed")
        case .photoDataSaveFailed:
            return String(localized: "error.photoDataSaveFailed")
        }
    }
}
