import AppKit

// Finder でファイルを選択状態で表示する（常に利用可能）
struct FinderAdapter: ExternalAppProtocol {
    let id = "com.apple.finder"
    let displayName = String(localized: "externalApp.finder")
    let symbolName = "folder"
    let isAvailable = true

    func open(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
