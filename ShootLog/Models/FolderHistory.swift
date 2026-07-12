import Foundation
import SwiftData

/// フォルダアクセス履歴。最大10件を保持する
@Model
final class FolderHistory {
    var url: URL
    var securityBookmark: Data  // セキュリティスコープブックマーク（再起動後のアクセスに必須）
    var lastAccessedAt: Date
    var displayName: String     // url.lastPathComponent

    init(url: URL, bookmark: Data) {
        self.url = url
        self.securityBookmark = bookmark
        self.lastAccessedAt = Date()
        self.displayName = url.lastPathComponent
    }
}
