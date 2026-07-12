import AppKit

// Adobe Lightroom Classic で開く
struct LightroomAdapter: ExternalAppProtocol {
    let id = "com.adobe.lightroomclassic"
    let displayName = "Lightroom Classic"
    let symbolName = "slider.horizontal.3"
    var isAvailable: Bool { appURL(bundleID: id) != nil }

    func open(url: URL) {
        openWithApp(bundleID: id, url: url)
    }
}
