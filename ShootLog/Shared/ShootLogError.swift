import Foundation

/// アプリ全体で使用するエラー定義
enum ShootLogError: LocalizedError {
    case exifReadFailed
    case unsupportedFormat(extension: String)
    case folderAccessDenied
    case bookmarkRestorationFailed

    var errorDescription: String? {
        switch self {
        case .exifReadFailed:
            return "EXIF情報の読み取りに失敗しました"
        case .unsupportedFormat(let ext):
            return "未対応の形式です: \(ext)"
        case .folderAccessDenied:
            return "フォルダへのアクセス権限がありません"
        case .bookmarkRestorationFailed:
            return "保存済みフォルダへのアクセスを復元できませんでした"
        }
    }
}
