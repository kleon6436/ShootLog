import Foundation

// 1ファイルぶんのセキュリティスコープ付きアクセスを、フォルダ全体のスコープとは独立して確保する
enum SecurityScopedBookmark {
    // ブックマークを新規作成・解決し、解決したURLでアクセスを開始する
    // （フォルダの権限スコープが既に有効な間のみ作成できる）。
    // 読み取り専用スコープの配下では読み書きのブックマークを作れないため、読み取り専用で作る。
    // 返したURLは呼び出し側が stopAccessingSecurityScopedResource() で解放する
    static func startAccessingFreshBookmark(for url: URL) throws -> URL {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var isStale = false
        let scopedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard scopedURL.startAccessingSecurityScopedResource() else {
            throw ShootLogError.folderAccessDenied
        }
        return scopedURL
    }
}
