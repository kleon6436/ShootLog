import AppKit

// Capture One で開く（バージョンに依存しないよう複数のバンドルIDを検索する）
struct CaptureOneAdapter: ExternalAppProtocol {
    let id = "com.captureone.captureone"
    let displayName = "Capture One"
    let symbolName = "camera.filters"

    private static let bundleIDs = [
        "com.captureone.captureone23",
        "com.captureone.captureone22",
        "com.captureone.captureone21",
        "com.captureone.captureone",
    ]

    var isAvailable: Bool {
        Self.bundleIDs.contains { appURL(bundleID: $0) != nil }
    }

    func open(url: URL) {
        guard let bundleID = Self.bundleIDs.first(where: { appURL(bundleID: $0) != nil }) else { return }
        openWithApp(bundleID: bundleID, url: url)
    }
}
