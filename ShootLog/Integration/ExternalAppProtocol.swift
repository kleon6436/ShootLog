import AppKit

// 外部アプリ連携のプロトコル。新しいアプリはこれに準拠して ExternalAppRegistry に登録する
protocol ExternalAppProtocol: Identifiable {
    var id: String { get }          // アダプター識別子（バンドルID）
    var displayName: String { get } // 表示名（例: "Adobe Photoshop"）
    var symbolName: String { get }  // SF Symbols アイコン名
    var isAvailable: Bool { get }   // インストール済みか確認
    func open(url: URL)             // 指定ファイルをそのアプリで開く
}

// バンドルIDからアプリURLを取得・起動するデフォルト実装
extension ExternalAppProtocol {
    func appURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func openWithApp(bundleID: String, url: URL) {
        guard let appURL = appURL(bundleID: bundleID) else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

// インストール済みの外部アプリアダプターを提供するレジストリ
final class ExternalAppRegistry: @unchecked Sendable {
    static let shared = ExternalAppRegistry()
    private init() {}

    // 登録された全アダプター（Finder は常に先頭）
    let allAdapters: [any ExternalAppProtocol] = [
        FinderAdapter(),
        PreviewAdapter(),
        PhotoshopAdapter(),
        LightroomAdapter(),
        CaptureOneAdapter(),
        AffinityPhotoAdapter(),
    ]

    // インストール済みアダプターのみ（UI 表示用）
    var availableAdapters: [any ExternalAppProtocol] {
        allAdapters.filter { $0.isAvailable }
    }
}
