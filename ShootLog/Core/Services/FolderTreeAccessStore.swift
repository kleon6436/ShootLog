import Foundation

// フォルダツリーの上位表示用に保存する許可1件
struct FolderTreeAccessGrant: Codable, Equatable {
    let path: String
    let bookmark: Data
}

// 上位フォルダの許可の保存先。スキーマ変更を避けるため @Model にせず UserDefaults へ置く。
// ボリュームごとに1件だけ持つ。解決に失敗しても消さない（NAS の再接続で復帰させるため）
struct FolderTreeAccessStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func grants() -> [FolderTreeAccessGrant] {
        guard let data = defaults.data(forKey: AppSettingsKeys.folderTreeAccessGrants) else { return [] }
        return (try? JSONDecoder().decode([FolderTreeAccessGrant].self, from: data)) ?? []
    }

    func grant(forVolumeOf url: URL) -> FolderTreeAccessGrant? {
        grants().first { isOnSameVolume($0, as: url) }
    }

    func save(_ url: URL, bookmark: Data) {
        var updated = grants().filter { !isOnSameVolume($0, as: url) }
        updated.append(FolderTreeAccessGrant(path: url.standardizedFileURL.path, bookmark: bookmark))
        write(updated)
    }

    func remove(forVolumeOf url: URL) {
        write(grants().filter { !isOnSameVolume($0, as: url) })
    }

    private func isOnSameVolume(_ grant: FolderTreeAccessGrant, as url: URL) -> Bool {
        FolderPathComponents.isSameFolder(
            FolderPathComponents.volumeRoot(of: URL(fileURLWithPath: grant.path, isDirectory: true)),
            FolderPathComponents.volumeRoot(of: url)
        )
    }

    private func write(_ grants: [FolderTreeAccessGrant]) {
        guard let data = try? JSONEncoder().encode(grants) else { return }
        defaults.set(data, forKey: AppSettingsKeys.folderTreeAccessGrants)
    }
}

// セキュリティスコープの実操作。テストでは署名なしでも動くスタブへ差し替える
struct FolderTreeAccessScope: Sendable {
    struct ResolvedBookmark: Sendable {
        let url: URL
        let isStale: Bool
    }

    // ブックマークの作成と解決はファイルシステムを参照するため、MainActor の外で呼ぶ
    var makeBookmark: @Sendable (URL) throws -> Data
    var resolve: @Sendable (Data) throws -> ResolvedBookmark
    var start: @MainActor (URL) -> Bool
    var stop: @MainActor (URL) -> Void

    static let live = FolderTreeAccessScope(
        // 読み取り専用に固定する。stale の更新でも読み書きへ戻さない
        makeBookmark: { url in
            try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        // アンマウント中のボリュームをマウントしたりダイアログを出したりしない
        resolve: { bookmark in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedBookmark(url: url, isStale: isStale)
        },
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}
