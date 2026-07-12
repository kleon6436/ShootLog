import AppKit

// Adobe Photoshop で開く
struct PhotoshopAdapter: ExternalAppProtocol {
    let id = "com.adobe.Photoshop"
    let displayName = "Photoshop"
    let symbolName = "wand.and.stars"
    var isAvailable: Bool { appURL(bundleID: id) != nil }

    func open(url: URL) {
        openWithApp(bundleID: id, url: url)
    }
}
