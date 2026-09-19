import AppKit

/// パスボードへの書き込み口。外部アプリ連携アダプター（`FinderAdapter` など）と同じ流儀で、
/// AppKit への依存を1か所に閉じ込めてテストからはスタブへ差し替えられるようにする
protocol PhotoPasteboardWriting: Sendable {
    /// プレーンテキストとして書き込む（ファイル名コピー用）
    func writeText(_ text: String)
    /// ファイルURLとして書き込む（パスコピー用）
    func writeFileURL(_ url: URL)
}

/// システムの汎用パスボード（`NSPasteboard.general`）へ書き込む実装
struct SystemPhotoPasteboardWriter: PhotoPasteboardWriting {
    func writeText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func writeFileURL(_ url: URL) {
        // テキストエディタへはパス文字列として、Finder やファイル選択欄へはファイルURLとして
        // 貼り付けられるよう、1つのパスボードアイテムに両方の型を載せる
        let item = NSPasteboardItem()
        item.setString(url.path, forType: .string)
        item.setString(url.absoluteString, forType: .fileURL)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
