import AppKit
import Foundation

// 上位フォルダの選択を Open Panel 上で検証する。エラーを投げるとパネルは開いたまま理由を表示する
final class FolderTreeAccessPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    static func validate(_ url: URL, forRoot root: URL) throws {
        guard FolderPathComponents.isValidTreeAccess(url, forRoot: root) else {
            throw ShootLogError.folderTreeAccessNotAncestor
        }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        try Self.validate(url, forRoot: root)
    }

    // 起動ディスクのルート "/" の許可だけは、他のボリュームやデスクトップ等にも及ぶため範囲を説明する
    static func message(forRoot root: URL) -> LocalizedStringResource {
        if FolderPathComponents.volumeRoot(of: root).path == "/" {
            return "openPanel.folderTree.message.startupVolume"
        }
        return "openPanel.folderTree.message"
    }
}

// フォルダツリーの上位表示に使う許可の取得・保持・解放を担当する。
// スコープはルートの bookmarkScopedURL とは独立して持つ（どちらを先に解放しても他方は読める）
extension ContentViewModel {
    // ツリーの根であり、移動できる範囲の上限
    var navigationBoundaryURL: URL? {
        treeAccessURL ?? rootFolderURL
    }

    // ルートがボリュームのルートなら上位が無いので、許可を求めない
    var canRequestTreeAccess: Bool {
        guard treeAccessURL == nil, let rootFolderURL else { return false }
        return !FolderPathComponents.isSameFolder(rootFolderURL, FolderPathComponents.volumeRoot(of: rootFolderURL))
    }

    // ルートを開いた直後に呼ぶ。許可が無ければ Open Panel を自動で出す（Sandbox の制約でパネルは省略できない）。
    // 写真の読み込みは止めないよう、パネルは別タスクで非モーダルに出す。
    // キャンセル・解除したボリュームでは、アプリを終了するまで再び自動では出さない
    func promptTreeAccessIfNeeded() {
        guard canRequestTreeAccess, !isPresentingTreeAccessPanel, let root = rootFolderURL else { return }
        let volumePath = FolderPathComponents.volumeRoot(of: root).path
        guard !declinedTreeAccessVolumePaths.contains(volumePath) else { return }
        isPresentingTreeAccessPanel = true
        let epoch = rootEpoch
        let prompt = treeAccessPrompt
        treeAccessPromptTask = Task {
            let selected = await prompt(root)
            isPresentingTreeAccessPanel = false
            // パネル表示中に別のルートへ切り替わったら、旧ルート向けの選択は使わない
            guard epoch == rootEpoch else { return }
            guard let selected else {
                declinedTreeAccessVolumePaths.insert(volumePath)
                return
            }
            await grantTreeAccess(to: selected)
        }
    }

    // 上位フォルダを選ばせる Open Panel。選ばれなければ nil
    static func presentTreeAccessPanel(forRoot root: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FolderPathComponents.volumeRoot(of: root)
        panel.message = String(localized: FolderTreeAccessPanelDelegate.message(forRoot: root))
        // 無効な選択はパネルを閉じる前に拒否する。閉じた後は Powerbox の権限が付与済みの可能性があるため。
        // panel.delegate は弱参照なので、パネルを閉じるまでここで保持する
        let delegate = FolderTreeAccessPanelDelegate(root: root)
        panel.delegate = delegate
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        withExtendedLifetime(delegate) {}
        guard response == .OK else { return nil }
        return panel.url
    }

    // Open Panel で選ばれたフォルダを検証し、有効なら許可として保存してスコープを開始する。
    // パネル側の検証（FolderTreeAccessPanelDelegate）を抜けた場合に備え、ここでも検証する。
    // テストから検証経路を確かめるため、パネルの表示とは分けておく
    func grantTreeAccess(to url: URL) async {
        guard treeAccessURL == nil, let root = rootFolderURL else { return }
        guard FolderPathComponents.isValidTreeAccess(url, forRoot: root) else {
            showToast(String(localized: "toast.folderTree.notAncestor"))
            return
        }
        treeAccessSyncGeneration &+= 1
        let generation = treeAccessSyncGeneration
        let scope = treeAccessScope
        do {
            let (bookmark, resolved) = try await Task.detached(priority: .userInitiated) {
                let bookmark = try scope.makeBookmark(url)
                return (bookmark, try scope.resolve(bookmark))
            }.value
            guard generation == treeAccessSyncGeneration else { return }
            guard FolderPathComponents.isValidTreeAccess(resolved.url, forRoot: root),
                  scope.start(resolved.url) else {
                throw ShootLogError.folderAccessDenied
            }
            treeAccessURL = resolved.url
            treeAccessStore.save(resolved.url, bookmark: bookmark)
        } catch {
            guard generation == treeAccessSyncGeneration else { return }
            self.error = ShootLogError.folderAccessDenied
        }
    }

    // 新しいルートに合わせて許可を切り替える。今の許可がそのまま有効なら保持し、
    // 範囲外なら解放して、保存済みの許可があれば復元する。
    // 呼び出し側は cancelPhotoStaging の完了後に呼ぶ（解放後の読み込み失敗を避けるため）
    func syncTreeAccess(for root: URL) async {
        if let treeAccessURL, FolderPathComponents.isValidTreeAccess(treeAccessURL, forRoot: root) { return }
        releaseTreeAccess()
        guard let grant = treeAccessStore.grant(forVolumeOf: root) else { return }
        let generation = treeAccessSyncGeneration
        let scope = treeAccessScope
        let bookmark = grant.bookmark
        let resolved = await Task.detached(priority: .userInitiated) { try? scope.resolve(bookmark) }.value
        // 移動・改名・未接続で祖先でなくなった許可は使わない。保存データは残す
        guard generation == treeAccessSyncGeneration,
              let resolved,
              FolderPathComponents.isValidTreeAccess(resolved.url, forRoot: root),
              scope.start(resolved.url) else { return }
        treeAccessURL = resolved.url
        guard resolved.isStale else { return }
        let url = resolved.url
        let refreshed = await Task.detached(priority: .utility) { try? scope.makeBookmark(url) }.value
        guard generation == treeAccessSyncGeneration, let refreshed else { return }
        treeAccessStore.save(url, bookmark: refreshed)
    }

    // 解放すると兄弟フォルダはすぐ読めなくなるため、ルートへ戻し終えてからスコープを止める。
    // 移動の上限は先に狭めて、戻している間に範囲外へ移動させない
    func revokeTreeAccess() async {
        guard let access = treeAccessURL, let rootFolderURL else { return }
        treeAccessSyncGeneration &+= 1
        treeAccessStore.remove(forVolumeOf: access)
        // 解除した直後に同じボリュームのフォルダを開いても、パネルを自動で出し直さない
        declinedTreeAccessVolumePaths.insert(FolderPathComponents.volumeRoot(of: rootFolderURL).path)
        treeAccessURL = nil
        if let currentFolderURL, !FolderPathComponents.isFolder(currentFolderURL, inside: rootFolderURL) {
            self.currentFolderURL = rootFolderURL
            currentPhotoSource = .folder(rootFolderURL)
            await loadFolderPhotos(rootFolderURL)
        }
        treeAccessScope.stop(access)
    }

    // 保存データは消さない。許可の無効化は revokeTreeAccess が担当する
    func releaseTreeAccess() {
        treeAccessSyncGeneration &+= 1
        guard let treeAccessURL else { return }
        self.treeAccessURL = nil
        treeAccessScope.stop(treeAccessURL)
    }
}
