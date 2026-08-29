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
    case superResolutionModelUnavailable
    case superResolutionFailed(reason: String)
    case superResolutionOutputTooLarge(outputMegapixels: Int, limit: Int)
    case superResolutionDestinationInSourceFolder
    case superResolutionOverwritesOriginal
    case superResolutionExportFailed
    case developRenderFailed
    case developExportFailed

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
        case .superResolutionModelUnavailable:
            return String(localized: "error.superResolutionModelUnavailable")
        case .superResolutionFailed:
            return String(localized: "error.superResolutionFailed")
        case .superResolutionOutputTooLarge(let outputMegapixels, let limit):
            return String(localized: "error.superResolutionOutputTooLarge \(outputMegapixels) \(limit)")
        case .superResolutionDestinationInSourceFolder:
            return String(localized: "error.superResolutionDestinationInSourceFolder")
        case .superResolutionOverwritesOriginal:
            return String(localized: "error.superResolutionOverwritesOriginal")
        case .superResolutionExportFailed:
            return String(localized: "error.superResolutionExportFailed")
        case .developRenderFailed:
            return String(localized: "error.developRenderFailed")
        case .developExportFailed:
            return String(localized: "error.developExportFailed")
        }
    }

    // 内部的な失敗理由。ユーザー向けではなく診断用のため翻訳しない
    var failureReason: String? {
        switch self {
        case .superResolutionFailed(let reason):
            return reason
        default:
            return nil
        }
    }
}
