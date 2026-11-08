import Foundation

// パスバー（FolderPathBar）の1要素。移動範囲の上限より上は移動不可、上限以下のフォルダは移動先、末尾はファイル
struct FolderPathComponent: Equatable, Identifiable {
    enum Kind: Equatable {
        // 移動範囲の上限より上の階層。セキュリティスコープの外なので移動させない
        case outsideRoot
        // 移動範囲の上限自身からその配下のフォルダ。クリックでそのフォルダへ移動できる
        case folderInRoot
        // 末尾の写真ファイル
        case file
    }

    let name: String
    let url: URL
    let kind: Kind

    var id: URL { url }
}

// パスの分解とルート配下の判定をまとめた純関数群。
// 判定は standardizedFileURL.pathComponents 単位の前方一致で行い、シンボリックリンクは解決しない
// （フォルダツリー側でリンクを除外しているため、論理パスで統一する）。
// 文字列の前方一致だと "/a/b" と "/a/bc" を区別できないため、必ずコンポーネント単位で比べる
enum FolderPathComponents {
    // url が root 自身か root 配下にあるか
    static func isFolder(_ url: URL, inside root: URL) -> Bool {
        let target = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard target.count >= rootComponents.count else { return false }
        return Array(target.prefix(rootComponents.count)) == rootComponents
    }

    // 末尾スラッシュの有無などの表記ゆれを除いて同じフォルダを指すか
    static func isSameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.pathComponents == rhs.standardizedFileURL.pathComponents
    }

    // url が属するボリュームのルート。/Volumes/X 配下は /Volumes/X、それ以外は "/"。
    // パスだけで判定し、ファイルシステムは参照しない
    static func volumeRoot(of url: URL) -> URL {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else {
            return URL(fileURLWithPath: "/", isDirectory: true)
        }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(3))), isDirectory: true)
    }

    // access がルートの上位表示の許可として有効か。ルートの祖先で、かつルートと同じボリューム内に限る
    // （"/" の許可は他のボリュームにも及ぶため、これがないとツリーの根に全ボリュームが並ぶ）
    static func isValidTreeAccess(_ access: URL, forRoot root: URL) -> Bool {
        !isSameFolder(access, root)
            && isFolder(root, inside: access)
            && isFolder(access, inside: volumeRoot(of: root))
    }

    // targetURL を先頭から順に分解する。外部ボリューム（/Volumes/X）配下は Finder と同じく
    // ボリューム自身から始め、"/" と "Volumes" は出さない。
    // 表示名の取得（FileManager.displayName）はファイルシステムを参照するため、
    // 呼び出し側は MainActor の外で実行する
    static func make(
        targetURL: URL,
        rootURL: URL,
        isFile: Bool,
        displayName: (URL) -> String = { FileManager.default.displayName(atPath: $0.path) }
    ) -> [FolderPathComponent] {
        let components = targetURL.standardizedFileURL.pathComponents
        guard !components.isEmpty else { return [] }
        let rootCount = rootURL.standardizedFileURL.pathComponents.count
        let isInsideRoot = isFolder(targetURL, inside: rootURL)
        let startIndex = components.count >= 3 && components[1] == "Volumes" ? 2 : 0

        return (startIndex..<components.count).map { index in
            let url = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
            let kind: FolderPathComponent.Kind
            if isFile && index == components.count - 1 {
                kind = .file
            } else if isInsideRoot && index >= rootCount - 1 {
                kind = .folderInRoot
            } else {
                kind = .outsideRoot
            }
            return FolderPathComponent(name: displayName(url), url: url, kind: kind)
        }
    }
}
