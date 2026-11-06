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
        navigate: @escaping FolderTreeViewModel.Navigator = { _ in }
    ) -> FolderTreeViewModel {
        FolderTreeViewModel(
            enumerate: { url in try await stub.enumerate(url) },
            navigationDebounce: debounce,
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
}
