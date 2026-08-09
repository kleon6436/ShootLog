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
            return "EXIF情報の読み取りに失敗しました"
        case .unsupportedFormat(let ext):
            return "未対応の形式です: \(ext)"
        case .folderAccessDenied:
            return "フォルダへのアクセス権限がありません"
        case .bookmarkRestorationFailed:
            return "保存済みフォルダへのアクセスを復元できませんでした"
        case .applicationInfoUnavailable(let name):
            return "「\(name)」のアプリ情報（バンドルID）を取得できませんでした"
        case .duplicateIntegrationApp(let name):
            return "「\(name)」はすでに連携アプリとして登録されています"
        case .settingsSaveFailed:
            return "連携アプリの設定を保存できませんでした"
        case .photoDataSaveFailed:
            return "写真データの保存に失敗しました"
        }
    }
}
