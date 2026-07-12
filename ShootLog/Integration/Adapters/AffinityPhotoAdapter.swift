import AppKit

// Affinity Photo で開く（バージョン1・2両対応）
struct AffinityPhotoAdapter: ExternalAppProtocol {
    let id = "com.seriflabs.affinityphoto2"
    let displayName = "Affinity Photo"
    let symbolName = "paintbrush"

    private static let bundleIDs = [
        "com.seriflabs.affinityphoto2",
        "com.seriflabs.affinityphoto",
    ]

    var isAvailable: Bool {
        Self.bundleIDs.contains { appURL(bundleID: $0) != nil }
    }

    func open(url: URL) {
        guard let bundleID = Self.bundleIDs.first(where: { appURL(bundleID: $0) != nil }) else { return }
        openWithApp(bundleID: bundleID, url: url)
    }
}
