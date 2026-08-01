import AppKit

// ユーザーが設定画面で追加したカスタム連携アプリのアダプター。
// アイコンは実アプリの .icns ではなくSF Symbolsの汎用アイコンで代替する
struct CustomAppAdapter: ExternalAppProtocol {
    let id: String              // 選択されたアプリのバンドルID
    let displayName: String
    var symbolName: String { "app.dashed" }
    var isAvailable: Bool { appURL(bundleID: id) != nil }

    func open(url: URL) {
        openWithApp(bundleID: id, url: url)
    }
}
