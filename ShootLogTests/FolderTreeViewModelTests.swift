import Foundation
import Testing

@testable import ShootLog

// 列挙のスタブ。呼び出しを記録し、指定したフォルダは release まで結果を返さない
@MainActor
private final class StubFolderEnumerator {
    var results: [URL: Result<[URL], any Error>] = [:]
    var gated: Set<URL> = []
    private(set) var calls: [URL] = []
    // 結果を返し終えたフォルダ（ゲートで待たせた列挙が実際に完了したことの確認用）
    private(set) var returned: [URL] = []
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var startWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func enumerate(_ url: URL) async throws -> [URL] {
        calls.append(url)
        if gated.contains(url) {
            startWaiters.removeValue(forKey: url)?.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                waiters[url, default: []].append(continuation)
            }
        }
        returned.append(url)
        return try results[url]?.get() ?? []
    }

    // ゲートで止めた列挙が実際に始まって待機に入るまで待つ
    func waitUntilGatedCallStarts(_ url: URL) async {
        guard waiters[url] == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters[url, default: []].append(continuation)
        }
    }

    func release(_ url: URL) {
        gated.remove(url)
        waiters.removeValue(forKey: url)?.forEach { $0.resume() }
    }
}

private struct StubEnumerationError: Error {}

@MainActor
struct FolderTreeViewModelTests {

    private func folder(_ path: String) -> URL {
        FolderTreeViewModel.normalized(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func makeTree(
        _ stub: StubFolderEnumerator,
        debounce: Duration = .milliseconds(1),
        navigate: @escaping FolderTreeViewModel.Navigator = { _ in },
        rootEpoch: @escaping @MainActor () -> Int = { 0 },
        volumeName: @escaping FolderTreeViewModel.VolumeNameResolver = { _ in "unused" }
    ) -> FolderTreeViewModel {
        FolderTreeViewModel(
            enumerate: { url in try await stub.enumerate(url) },
            navigationDebounce: debounce,
            rootEpoch: rootEpoch,
            volumeName: volumeName,
            navigate: navigate
        )
    }

    @Test func setRootExpandsAndLoadsRootOnce() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        stub.results[root] = .success([URL(fileURLWithPath: "/r/b"), URL(fileURLWithPath: "/r/a")])
        let tree = makeTree(stub)

        tree.setRoot(root)
        await tree.waitForPendingLoads()

        #expect(tree.root == root)
        #expect(tree.isExpanded(root))
        #expect(tree.children[root] == [folder("/r/b"), folder("/r/a")])
        #expect(stub.calls == [root])
    }

    // 同じルート（表記ゆれを含む）で呼び直しても、状態を失わず読み込みもしない
    @Test func setRootIsIdempotent() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let child = folder("/r/a")
        stub.results[root] = .success([child])
        let tree = makeTree(stub)

        tree.setRoot(root)
        await tree.waitForPendingLoads()
        tree.setExpanded(child, true)
        await tree.waitForPendingLoads()

        tree.setRoot(URL(fileURLWithPath: "/r"))
        tree.setRoot(root)

        #expect(stub.calls == [root, child])
        #expect(tree.isExpanded(child))
        #expect(tree.loading.isEmpty)
    }

    // 展開すると1回だけ読み込み、折りたたんでから再展開すると読み込み直す
    @Test func expandLoadsOnceAndReexpandReloads() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let child = folder("/r/a")
        stub.results[root] = .success([child])
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()

        tree.setExpanded(child, true)
        tree.setExpanded(child, true)
        await tree.waitForPendingLoads()
        #expect(stub.calls.filter { $0 == child }.count == 1)
        #expect(tree.children[child] == [])

        tree.toggleExpanded(child)
        #expect(!tree.isExpanded(child))
        tree.toggleExpanded(child)
        await tree.waitForPendingLoads()
        #expect(stub.calls.filter { $0 == child }.count == 2)
    }

    // ルート切替の後に遅れて届いた旧ルートの結果は捨てる
    @Test func lateResultAfterRootSwitchIsDiscarded() async throws {
        let stub = StubFolderEnumerator()
        let oldRoot = folder("/old")
        let newRoot = folder("/new")
        stub.results[oldRoot] = .success([folder("/old/a")])
        stub.results[newRoot] = .success([folder("/new/b")])
        stub.gated = [oldRoot]
        let tree = makeTree(stub)

        tree.setRoot(oldRoot)
        tree.setRoot(newRoot)
        await stub.waitUntilGatedCallStarts(oldRoot)
        // 旧ルートの列挙がルート切替後もまだ結果を返していないことを確かめてから解放する
        #expect(stub.calls.contains(oldRoot))
        #expect(!stub.returned.contains(oldRoot))
        stub.release(oldRoot)
        // 旧ルートの Task が結果を受け取って破棄し終えるまで待つ
        await tree.waitForPendingLoads()

        #expect(stub.returned.contains(oldRoot))
        #expect(tree.root == newRoot)
        #expect(tree.children[oldRoot] == nil)
        #expect(tree.children[newRoot] == [folder("/new/b")])
        #expect(tree.loading.isEmpty)
    }

    @Test func revealExpandsAncestors() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let tree = makeTree(stub)
        tree.setRoot(root)

        tree.reveal(URL(fileURLWithPath: "/r/a/b/c"))
        await tree.waitForPendingLoads()

        #expect(tree.isExpanded(root))
        #expect(tree.isExpanded(folder("/r/a")))
        #expect(tree.isExpanded(folder("/r/a/b")))
        #expect(!tree.isExpanded(folder("/r/a/b/c")))

        // ルートの外は展開しない
        tree.reveal(URL(fileURLWithPath: "/other/x"))
        #expect(!tree.isExpanded(folder("/other")))
    }

    @Test func failureIsRecorded() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        stub.results[root] = .failure(StubEnumerationError())
        let tree = makeTree(stub)

        tree.setRoot(root)
        await tree.waitForPendingLoads()

        #expect(tree.failed.contains(root))
        #expect(tree.children[root] == nil)
    }

    // デバウンス中に連続で要求すると、最後の1件だけが移動処理へ渡る。
    // 要求は同期的に続けて出すため、デバウンスの長さや実時間に結果が左右されない
    @Test func debounceNavigatesOnlyLastRequest() async throws {
        let stub = StubFolderEnumerator()
        var navigated: [URL] = []
        let tree = makeTree(stub, debounce: .milliseconds(150)) { url in
            navigated.append(url)
        }
        tree.setRoot(folder("/r"))

        let targets = ["a", "b", "c", "d", "e"].map { folder("/r/\($0)") }
        for target in targets {
            tree.requestNavigate(target)
        }
        #expect(tree.pendingSelection == targets.last)

        await tree.waitForPendingNavigation()

        #expect(navigated == [folder("/r/e")])
        #expect(tree.pendingSelection == nil)
    }

    // ツリーのクリック（デバウンス待ち）の直後にパスバーから移動すると、パスバー側の移動先が最終結果になる
    @Test func immediateRequestOverridesPendingTreeRequest() async throws {
        let stub = StubFolderEnumerator()
        var navigated: [URL] = []
        // 長いデバウンスでツリー側の要求を確実に待機中にしておく
        let tree = makeTree(stub, debounce: .seconds(60)) { url in
            navigated.append(url)
        }
        tree.setRoot(folder("/r"))

        tree.requestNavigate(folder("/r/tree"))
        tree.requestNavigate(folder("/r/pathBar"), isDebounced: false)
        await tree.waitForPendingNavigation()

        #expect(navigated == [folder("/r/pathBar")])
        #expect(tree.pendingSelection == nil)
    }

    // MARK: - 根を維持したままのルート切替

    // デバウンス中に別のフォルダが開かれたら（根は同じまま）、古いクリックは捨ててハイライトも戻す
    @Test func requestIsDiscardedWhenRootEpochChanges() async throws {
        let stub = StubFolderEnumerator()
        var navigated: [URL] = []
        var epoch = 0
        let tree = makeTree(stub, navigate: { url in navigated.append(url) }, rootEpoch: { epoch })
        tree.setRoot(folder("/r"))

        tree.requestNavigate(folder("/r/a"))
        epoch += 1
        await tree.waitForPendingNavigation()

        #expect(navigated.isEmpty)
        #expect(tree.pendingSelection == nil)
        #expect(tree.root == folder("/r"))

        // 変更後に受け付けた要求は通常どおり移動する
        tree.requestNavigate(folder("/r/b"))
        await tree.waitForPendingNavigation()
        #expect(navigated == [folder("/r/b")])
    }

    // 根が同じなら展開状態を保ったまま、別の枝の対象も見せられる
    @Test func revealKeepsRootAndExpandedState() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let (a, b) = (folder("/r/a"), folder("/r/b"))
        stub.results[root] = .success([a, b])
        stub.results[b] = .success([folder("/r/b/c")])
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()
        tree.setExpanded(a, true)
        await tree.waitForPendingLoads()

        tree.reveal(folder("/r/b/c"))
        await tree.waitForPendingLoads()

        #expect(tree.root == root)
        #expect(tree.isExpanded(a))
        #expect(tree.isExpanded(b))
        #expect(tree.scrollRequest?.url == folder("/r/b/c"))
    }

    // MARK: - 展開済み祖先の再読込

    @Test func revealDoesNotReloadAncestorThatHasNextLevel() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let a = folder("/r/a")
        stub.results[root] = .success([a])
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()

        tree.reveal(a)
        await tree.waitForPendingLoads()

        #expect(stub.calls == [root])
    }

    // 親を読み込んだ後に作られたフォルダなど、子に次の階層が無い祖先だけを読み直す
    @Test func revealReloadsAncestorMissingNextLevel() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let (a, new) = (folder("/r/a"), folder("/r/new"))
        stub.results[root] = .success([a])
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()

        stub.results[root] = .success([a, new])
        tree.reveal(new)
        #expect(tree.revealTarget == new)
        await tree.waitForPendingLoads()

        #expect(stub.calls == [root, root])
        #expect(tree.children[root] == [a, new])
        #expect(tree.revealTarget == nil)
        #expect(tree.scrollRequest?.url == new)
    }

    // 一覧に出ないフォルダは、何度見せようとしても祖先を1度しか読み直さない
    @Test func hiddenFolderReloadsAncestorOnlyOnce() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let a = folder("/r/a")
        let hidden = folder("/r/.hidden")
        stub.results[root] = .success([a])
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()

        for target in [hidden, a, hidden, folder("/r/.hidden/sub"), hidden] {
            tree.reveal(target)
            await tree.waitForPendingLoads()
        }

        // 初回の列挙 + 隠しフォルダを探す1回
        #expect(stub.calls.filter { $0 == root }.count == 2)

        // 別の新しいフォルダは初回に拾える
        let new = folder("/r/new")
        stub.results[root] = .success([a, new])
        tree.reveal(new)
        await tree.waitForPendingLoads()
        #expect(stub.calls.filter { $0 == root }.count == 3)
        #expect(tree.children[root] == [a, new])
    }

    // 一覧に現れた後で消えて作り直されたフォルダも、初回と同じく拾い直せる
    @Test func folderRecreatedAfterListingIsPickedUpAgain() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let new = folder("/r/new")
        stub.results[root] = .success([])
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()

        stub.results[root] = .success([new])
        tree.reveal(new)
        await tree.waitForPendingLoads()
        #expect(tree.children[root] == [new])

        // 利用者の展開し直しで一覧から消えた後、再び作られる
        stub.results[root] = .success([])
        tree.toggleExpanded(root)
        tree.toggleExpanded(root)
        await tree.waitForPendingLoads()
        #expect(tree.children[root] == [])

        stub.results[root] = .success([new])
        tree.reveal(new)
        await tree.waitForPendingLoads()
        #expect(tree.children[root] == [new])
    }

    // 列挙に失敗した祖先は自動で読み直さない。展開し直せば読み直す
    @Test func failedAncestorIsNotRetriedAutomatically() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let a = folder("/r/a")
        stub.results[root] = .success([a])
        stub.results[a] = .failure(StubEnumerationError())
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()
        tree.setExpanded(a, true)
        await tree.waitForPendingLoads()
        #expect(tree.failed.contains(a))

        for _ in 0..<3 {
            tree.reveal(folder("/r/a/b"))
            #expect(tree.failed.contains(a))
            #expect(!tree.loading.contains(a))
            await tree.waitForPendingLoads()
        }
        #expect(stub.calls.filter { $0 == a }.count == 1)

        // 折りたたんだ状態から reveal で開くときも再試行しない
        tree.setExpanded(a, false)
        tree.reveal(folder("/r/a/b"))
        await tree.waitForPendingLoads()
        #expect(tree.isExpanded(a))
        #expect(stub.calls.filter { $0 == a }.count == 1)

        tree.toggleExpanded(a)
        tree.toggleExpanded(a)
        await tree.waitForPendingLoads()
        #expect(stub.calls.filter { $0 == a }.count == 2)
    }

    // 根の列挙に失敗した場合も同じ
    @Test func failedRootIsNotRetriedAutomatically() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        stub.results[root] = .failure(StubEnumerationError())
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()

        for _ in 0..<3 {
            tree.reveal(folder("/r/a"))
            await tree.waitForPendingLoads()
        }

        #expect(stub.calls == [root])
        #expect(tree.failed.contains(root))
    }

    // MARK: - 読み込み後のスクロール

    // 親の読み込みが終わるまではスクロールせず、終わったら1度だけ要求する
    @Test func scrollRequestWaitsForParentLoad() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let (a, target) = (folder("/r/a"), folder("/r/a/target"))
        stub.results[root] = .success([a])
        stub.results[a] = .success([target])
        stub.gated = [a]
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()

        tree.reveal(target)
        await stub.waitUntilGatedCallStarts(a)
        #expect(tree.revealTarget == target)
        #expect(tree.scrollRequest == nil)

        stub.release(a)
        await tree.waitForPendingLoads()

        #expect(tree.revealTarget == nil)
        #expect(tree.scrollRequest?.url == target)

        // 利用者が別の行を展開しても、見せ終えた対象へ戻らない
        let requestID = tree.scrollRequest?.id
        tree.setExpanded(target, true)
        await tree.waitForPendingLoads()
        #expect(tree.scrollRequest?.id == requestID)
    }

    // 隠しフォルダのように行が現れない対象ではスクロールしない
    @Test func noScrollRequestWhenRowNeverAppears() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        stub.results[root] = .success([folder("/r/a")])
        let tree = makeTree(stub)
        tree.setRoot(root)
        await tree.waitForPendingLoads()

        tree.reveal(folder("/r/.hidden"))
        await tree.waitForPendingLoads()
        tree.setExpanded(folder("/r/a"), true)
        await tree.waitForPendingLoads()

        #expect(tree.scrollRequest == nil)
    }

    // 同じ行への再度の reveal も別の要求として View へ届く
    @Test func repeatedRevealIssuesNewScrollRequest() async throws {
        let stub = StubFolderEnumerator()
        let root = folder("/r")
        let tree = makeTree(stub)
        tree.setRoot(root)

        tree.reveal(root)
        let first = try #require(tree.scrollRequest)
        tree.reveal(root)
        let second = try #require(tree.scrollRequest)

        #expect(first.url == root)
        #expect(first != second)
    }

    // MARK: - 根の表示名

    @Test func rootSlashUsesVolumeName() async throws {
        let stub = StubFolderEnumerator()
        let tree = makeTree(stub, volumeName: { _ in "Macintosh HD" })

        tree.setRoot(folder("/"))
        await tree.waitForPendingLoads()

        #expect(tree.displayName(for: folder("/")) == "Macintosh HD")

        tree.setRoot(folder("/Volumes/X"))
        await tree.waitForPendingLoads()

        #expect(tree.rootVolumeName == nil)
        #expect(tree.displayName(for: folder("/Volumes/X")) == "X")
    }
}
