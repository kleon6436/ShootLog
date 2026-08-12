import AppKit

// macOS プレビュー.app で開く
struct PreviewAdapter: ExternalAppProtocol {
    let id = "com.apple.Preview"
    let displayName = String(localized: "externalApp.preview")
    let symbolName = "eye"
    var isAvailable: Bool { appURL(bundleID: id) != nil }

    func open(url: URL) {
        openWithApp(bundleID: id, url: url)
    }
}
