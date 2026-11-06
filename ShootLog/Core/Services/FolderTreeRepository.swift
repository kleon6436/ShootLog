import Foundation

// フォルダツリー用に、指定フォルダ直下のサブフォルダを列挙するリポジトリ（ステートレス）。
// PhotoRepository と同じく呼び出し側で Task.detached して MainActor の外で実行する
enum FolderTreeRepository {
    // 直下のサブフォルダのみを返す。隠しフォルダ・パッケージ（.app / .photoslibrary 等）・
    // シンボリックリンクは除外する（リンクはルートの外へ出られるため）。
    // 並びは Finder と同じ自然順（localizedStandardCompare、"10" が "9" の後）
    static func childFolders(of url: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        )
        return contents
            .filter { child in
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return false }
                return values.isDirectory == true
                    && values.isPackage != true
                    && values.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
