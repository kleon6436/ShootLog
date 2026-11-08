import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

// ルート配下のサブフォルダ移動（navigateToFolder）の検証。
// rootFolderURL / currentFolderURL / currentPhotoSource は直接設定し、移動だけを実経路で通す
// （PreviewGenerator.shared などのバックグラウンド処理は実際に動くが、小さな PNG なので許容する）
@MainActor
@Suite(.serialized)
struct ContentViewModelFolderNavigationTests {

    private struct Fixture {
        let content: ContentViewModel
        let context: ModelContext
        let sandbox: URL
        let root: URL
        let sub: URL
        let grandchild: URL
        let sibling: URL
        let defaultsSuiteName: String
        let scope: StubTreeAccessScope
        let store: FolderTreeAccessStore
        let prompt: StubTreeAccessPrompt
    }

    // 自動で出す上位フォルダのパネルの代わり。呼ばれたルートを記録し、決めておいた選択を返す
    @MainActor
    private final class StubTreeAccessPrompt {
        var requestedRoots: [URL] = []
        var selection: URL?
    }

    // スコープ操作の呼び出しを記録するスタブ。ブックマークの中身はパスの文字列とする
    @MainActor
    private final class StubTreeAccessScope {
        var started: [URL] = []
        var stopped: [URL] = []
        // スコープを止めた時点の表示フォルダと写真（解放の順序の確認用）
        var stateAtStop: [(folder: URL?, photoNames: Set<String>)] = []
        var onStop: (() -> (folder: URL?, photoNames: Set<String>))?
        let bookmarkRequests = LockedCounter()
        let resolveGate = ResolveGate()
        nonisolated(unsafe) var resolvedOverride: URL?
        nonisolated(unsafe) var isStale = false

        var scope: FolderTreeAccessScope {
            FolderTreeAccessScope(
                makeBookmark: { [bookmarkRequests] url in
                    bookmarkRequests.increment()
                    return Data(url.path.utf8)
                },
                resolve: { [resolveGate, weak self] data in
                    resolveGate.passThrough()
                    let path = String(decoding: data, as: UTF8.self)
                    return FolderTreeAccessScope.ResolvedBookmark(
                        url: self?.resolvedOverride ?? URL(fileURLWithPath: path, isDirectory: true),
                        isStale: self?.isStale ?? false
                    )
                },
                start: { [weak self] url in
                    self?.started.append(url)
                    return true
                },
                stop: { [weak self] url in
                    self?.stopped.append(url)
                    if let state = self?.onStop?() { self?.stateAtStop.append(state) }
                }
            )
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    // 解決処理を止めておくためのゲート。解決は MainActor の外で走るのでブロックしてよい
    private final class ResolveGate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var isClosed = false
        private var entered = false

        var hasEntered: Bool { lock.withLock { entered } }
        func close() { lock.withLock { isClosed = true } }
        func open() { semaphore.signal() }
        // 閉じている間に最初に来た1回だけを止める
        func passThrough() {
            let shouldWait = lock.withLock {
                let wasClosed = isClosed
                entered = true
                isClosed = false
                return wasClosed
            }
            if shouldWait { semaphore.wait() }
        }
    }

    // root/{r1.png, sub/{s1.png, s2.png, grandchild/g1.png}} を作り、root を開いた状態にする
    private func makeFixture() throws -> Fixture {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
            LensCorrectionProfile.self, FolderHistory.self, IntegrationAppSetting.self, MaskRaster.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let content = ContentViewModel()
        content.modelContext = context

        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FolderNavigationTests-\(UUID().uuidString)", isDirectory: true)
        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        let grandchild = sub.appendingPathComponent("grandchild", isDirectory: true)
        try FileManager.default.createDirectory(at: grandchild, withIntermediateDirectories: true)
        try writePNG(to: root.appendingPathComponent("r1.png"))
        try writePNG(to: sub.appendingPathComponent("s1.png"))
        try writePNG(to: sub.appendingPathComponent("s2.png"))
        try writePNG(to: grandchild.appendingPathComponent("g1.png"))
        let sibling = sandbox.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try writePNG(to: sibling.appendingPathComponent("b1.png"))

        // 実際の設定に触れないよう、許可の保存先はテストごとに分ける
        let suiteName = "FolderNavigationTests-\(UUID().uuidString)"
        let store = FolderTreeAccessStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
        let scope = StubTreeAccessScope()
        scope.onStop = { [weak content] in
            (content?.currentFolderURL, Set(content?.photos.map(\.fileURL.lastPathComponent) ?? []))
        }
        content.treeAccessStore = store
        content.treeAccessScope = scope.scope
        let prompt = StubTreeAccessPrompt()
        content.treeAccessPrompt = { [prompt] root in
            prompt.requestedRoots.append(root)
            return prompt.selection
        }

        content.rootFolderURL = root
        content.currentFolderURL = root
        content.currentPhotoSource = .folder(root)
        return Fixture(
            content: content, context: context, sandbox: sandbox, root: root, sub: sub, grandchild: grandchild,
            sibling: sibling, defaultsSuiteName: suiteName, scope: scope, store: store, prompt: prompt
        )
    }

    // 後片付け。バックグラウンドの生成処理を止めてから作業ディレクトリを消す
    private func tearDown(_ fixture: Fixture) async {
        await fixture.content.cancelPhotoStaging()
        try? FileManager.default.removeItem(at: fixture.sandbox)
        UserDefaults(suiteName: fixture.defaultsSuiteName)?.removePersistentDomain(forName: fixture.defaultsSuiteName)
    }

    /// 0バイトでない小さな PNG を書き出す
    private func writePNG(to url: URL) throws {
        let width = 8
        let height = 8
        let pixels = [UInt8](repeating: 128, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func photoNames(_ content: ContentViewModel) -> Set<String> {
        Set(content.photos.map(\.fileURL.lastPathComponent))
    }

    // MARK: - ルート配下の判定

    @Test func rejectsFoldersOutsideRoot() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        // "/…/root" と前方一致する兄弟フォルダ（"/a/b" と "/a/bc" の関係）
        let sibling = fixture.sandbox.appendingPathComponent("rootbc", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        await content.navigateToFolder(sibling)
        await content.navigateToFolder(fixture.sandbox)

        #expect(content.currentFolderURL == fixture.root)
        #expect(content.currentPhotoSource == .folder(fixture.root))
        await tearDown(fixture)
    }

    // MARK: - 移動

    // 移動先の直下の写真だけが一覧に入り、ルート・履歴は変わらない
    @Test func navigatesIntoSubfolderWithoutTouchingRootOrHistory() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.context.insert(FolderHistory(url: fixture.root, bookmark: Data()))
        try fixture.context.save()
        content.loadHistories(checkAvailability: false)
        let historyCount = content.folderHistories.count

        await content.navigateToFolder(fixture.sub)

        #expect(content.currentFolderURL == fixture.sub)
        #expect(content.currentPhotoSource == .folder(fixture.sub))
        #expect(content.rootFolderURL == fixture.root)
        #expect(photoNames(content) == ["s1.png", "s2.png"])
        #expect(content.folderHistories.count == historyCount)
        #expect(try fixture.context.fetchCount(FetchDescriptor<FolderHistory>()) == historyCount)
        #expect(content.error == nil)
        await tearDown(fixture)
    }

    @Test func navigatesToEnclosingFolderWithinRoot() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        #expect(!content.canNavigateToEnclosingFolder)

        await content.navigateToFolder(fixture.grandchild)
        #expect(photoNames(content) == ["g1.png"])
        #expect(content.canNavigateToEnclosingFolder)

        await content.navigateToEnclosingFolder()
        #expect(FolderPathComponents.isSameFolder(try #require(content.currentFolderURL), fixture.sub))

        await content.navigateToEnclosingFolder()
        #expect(FolderPathComponents.isSameFolder(try #require(content.currentFolderURL), fixture.root))
        #expect(!content.canNavigateToEnclosingFolder)

        // ルートより上へは出ない
        await content.navigateToEnclosingFolder()
        #expect(FolderPathComponents.isSameFolder(try #require(content.currentFolderURL), fixture.root))
        #expect(photoNames(content) == ["r1.png"])
        await tearDown(fixture)
    }

    // MARK: - 書き出しジョブ

    // サブフォルダへの移動では書き出しを中断せず、ルートが変わったときだけ中断する
    @Test func exportJobsSurviveSubfolderNavigationButNotRootChange() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        let upscaleTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let developTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        content.upscaleExportTask = upscaleTask
        content.developExportTask = developTask

        await content.navigateToFolder(fixture.sub)

        #expect(!upscaleTask.isCancelled)
        #expect(!developTask.isCancelled)

        content.rootFolderURL = fixture.sandbox

        #expect(upscaleTask.isCancelled)
        #expect(developTask.isCancelled)
        await tearDown(fixture)
    }

    // MARK: - 消えたフォルダ

    // 削除されたサブフォルダへ移動すると、アラートを出さずにルートへ戻ってトーストで知らせる
    @Test func missingSubfolderFallsBackToRootWithoutAlert() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        try FileManager.default.removeItem(at: fixture.sub)

        await content.navigateToFolder(fixture.sub)

        #expect(content.error == nil)
        #expect(content.currentFolderURL == fixture.root)
        #expect(content.currentPhotoSource == .folder(fixture.root))
        #expect(content.toastMessage == String(localized: "toast.folder.missingFallback"))
        #expect(photoNames(content) == ["r1.png"])
        await tearDown(fixture)
    }

    // 表示中のサブフォルダが消えた後に同じフォルダを選び直すと、読み込み直してルートへ戻る
    @Test func reselectingMissingCurrentFolderFallsBackToRoot() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.navigateToFolder(fixture.sub)
        try FileManager.default.removeItem(at: fixture.sub)

        await content.navigateToFolder(fixture.sub)

        #expect(content.error == nil)
        #expect(content.currentFolderURL == fixture.root)
        #expect(content.toastMessage == String(localized: "toast.folder.missingFallback"))
        #expect(photoNames(content) == ["r1.png"])
        await tearDown(fixture)
    }

    // 存在する表示中フォルダを選び直しても読み込み直さない
    @Test func reselectingExistingCurrentFolderIsNoOp() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.navigateToFolder(fixture.sub)
        let photosBefore = content.photos.map(\.id)

        await content.navigateToFolder(fixture.sub)

        #expect(content.photos.map(\.id) == photosBefore)
        #expect(content.currentFolderURL == fixture.sub)
        await tearDown(fixture)
    }

    // ルート自体が消えた場合は従来どおりアラートにする
    @Test func missingRootStillReportsError() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.navigateToFolder(fixture.sub)
        try FileManager.default.removeItem(at: fixture.root)

        await content.navigateToFolder(fixture.root)

        #expect(content.error != nil)
        await tearDown(fixture)
    }

    // MARK: - 移動時に保持・リセットする状態

    @Test func searchAndFavoritesFilterArePreservedButAICategoriesCleared() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        let sidebar = SidebarViewModel(content: content)
        sidebar.searchText = "s1"
        content.showFavoritesOnly = true
        content.selectedAICategories = [.animal]

        await content.navigateToFolder(fixture.sub)

        #expect(sidebar.searchText == "s1")
        #expect(content.showFavoritesOnly)
        #expect(content.selectedAICategories.isEmpty)
        await tearDown(fixture)
    }

    // MARK: - 履歴からの復元失敗

    // 新しいフォルダのブックマークを作れなかったら、旧ルートの表示を残さない
    @Test func failedSelectFolderClearsFolderState() async throws {
        let fixture = try makeFixture()
        let content = fixture.content

        await content.selectFolder(url: fixture.sandbox.appendingPathComponent("missing", isDirectory: true))

        #expect(content.rootFolderURL == nil)
        #expect(content.currentFolderURL == nil)
        #expect(content.currentPhotoSource == nil)
        #expect(content.error != nil)
        await tearDown(fixture)
    }

    // modelContext が無く復元を始められない場合も、スコープ解放後の旧ルートを残さない
    @Test func restoreWithoutContextClearsFolderState() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        let history = FolderHistory(url: fixture.root, bookmark: Data())
        content.modelContext = nil

        await content.restoreFolder(history)

        #expect(content.rootFolderURL == nil)
        #expect(content.currentFolderURL == nil)
        #expect(content.currentPhotoSource == nil)
        await tearDown(fixture)
    }

    // 復元に失敗したら、スコープの無い旧ルートを残さずフォルダ表示ごと閉じる
    @Test func failedRestoreClearsFolderState() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        let history = FolderHistory(url: fixture.root, bookmark: Data("broken".utf8))
        fixture.context.insert(history)

        await content.restoreFolder(history)

        #expect(content.rootFolderURL == nil)
        #expect(content.currentFolderURL == nil)
        #expect(content.currentPhotoSource == nil)
        #expect(content.error != nil)
        await tearDown(fixture)
    }

    // MARK: - 上位フォルダの許可がある状態の移動

    // 兄弟フォルダへ移動しても、ルート・履歴の件数と順序は変わらない
    @Test func navigatesToSiblingWithinGrantWithoutTouchingHistory() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        let older = FolderHistory(url: fixture.sub, bookmark: Data())
        older.lastAccessedAt = Date().addingTimeInterval(-60)
        fixture.context.insert(FolderHistory(url: fixture.root, bookmark: Data()))
        fixture.context.insert(older)
        try fixture.context.save()
        content.loadHistories(checkAvailability: false)
        let historyOrder = content.folderHistories.map(\.persistentModelID)
        content.treeAccessURL = fixture.sandbox

        await content.navigateToFolder(fixture.sibling)

        #expect(content.currentFolderURL == fixture.sibling)
        #expect(content.currentPhotoSource == .folder(fixture.sibling))
        #expect(content.rootFolderURL == fixture.root)
        #expect(photoNames(content) == ["b1.png"])
        #expect(content.folderHistories.map(\.persistentModelID) == historyOrder)
        #expect(content.error == nil)
        await tearDown(fixture)
    }

    @Test func rejectsFoldersOutsideGrant() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        content.treeAccessURL = fixture.sandbox

        await content.navigateToFolder(fixture.sandbox.deletingLastPathComponent())

        #expect(content.currentFolderURL == fixture.root)
        await tearDown(fixture)
    }

    // ⌘↑ は許可の根まで上がり、そこで止まる
    @Test func enclosingNavigationStopsAtGrant() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        content.treeAccessURL = fixture.sandbox
        #expect(content.canNavigateToEnclosingFolder)

        await content.navigateToEnclosingFolder()

        #expect(FolderPathComponents.isSameFolder(try #require(content.currentFolderURL), fixture.sandbox))
        #expect(!content.canNavigateToEnclosingFolder)
        await content.navigateToEnclosingFolder()
        #expect(FolderPathComponents.isSameFolder(try #require(content.currentFolderURL), fixture.sandbox))
        await tearDown(fixture)
    }

    // 読めない兄弟フォルダへ移動すると、アラートを出さずにルートへ戻ってトーストで知らせる
    @Test func unreadableSiblingFallsBackToRootWithoutAlert() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        content.treeAccessURL = fixture.sandbox
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.sibling.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.sibling.path)
        }

        await content.navigateToFolder(fixture.sibling)

        #expect(content.error == nil)
        #expect(content.currentFolderURL == fixture.root)
        #expect(content.currentPhotoSource == .folder(fixture.root))
        #expect(content.toastMessage == String(localized: "toast.folder.accessFailedFallback"))
        #expect(photoNames(content) == ["r1.png"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.sibling.path)
        await tearDown(fixture)
    }

    // フォルダが無い・権限が無い以外のスキャンエラーは、ルートへ戻さず従来どおりアラートにする
    // （通常ファイルをフォルダとして読むと NSFileReadUnknownError になる）
    @Test func otherScanErrorKeepsAlert() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        let file = fixture.root.appendingPathComponent("r1.png")

        await content.navigateToFolder(file)

        let error = try #require(content.error) as NSError
        #expect(error.domain == NSCocoaErrorDomain)
        #expect(error.code == CocoaError.fileReadUnknown.rawValue)
        #expect(content.toastMessage == nil)
        #expect(content.currentFolderURL == file)
        #expect(!content.isLoading)
        await tearDown(fixture)
    }

    @Test func exportJobsSurviveSiblingNavigation() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        content.treeAccessURL = fixture.sandbox
        let upscaleTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let developTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        content.upscaleExportTask = upscaleTask
        content.developExportTask = developTask

        await content.navigateToFolder(fixture.sibling)

        #expect(!upscaleTask.isCancelled)
        #expect(!developTask.isCancelled)
        upscaleTask.cancel()
        developTask.cancel()
        await tearDown(fixture)
    }

    // MARK: - 許可の取得

    @Test func grantingAncestorSavesAndStartsScope() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        #expect(content.canRequestTreeAccess)
        #expect(content.navigationBoundaryURL == fixture.root)

        await content.grantTreeAccess(to: fixture.sandbox)

        #expect(FolderPathComponents.isSameFolder(try #require(content.treeAccessURL), fixture.sandbox))
        #expect(FolderPathComponents.isSameFolder(try #require(content.navigationBoundaryURL), fixture.sandbox))
        #expect(!content.canRequestTreeAccess)
        #expect(fixture.scope.started.count == 1)
        #expect(fixture.store.grants().count == 1)
        #expect(content.rootFolderURL == fixture.root)
        #expect(content.toastMessage == nil)
        await tearDown(fixture)
    }

    // 祖先以外を選ぶと、トーストを出して保存しない
    @Test func grantingNonAncestorShowsToastAndDoesNotSave() async throws {
        let fixture = try makeFixture()
        let content = fixture.content

        await content.grantTreeAccess(to: fixture.sibling)

        #expect(content.treeAccessURL == nil)
        #expect(content.toastMessage == String(localized: "toast.folderTree.notAncestor"))
        #expect(fixture.store.grants().isEmpty)
        #expect(fixture.scope.bookmarkRequests.value == 0)
        await tearDown(fixture)
    }

    // 別ボリュームの祖先（DataDisk のルートに対する "/"）も同じく受け付けない
    @Test func grantingAncestorOnOtherVolumeShowsToastAndDoesNotSave() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        content.rootFolderURL = URL(fileURLWithPath: "/Volumes/DataDisk/photos", isDirectory: true)

        await content.grantTreeAccess(to: URL(fileURLWithPath: "/", isDirectory: true))

        #expect(content.treeAccessURL == nil)
        #expect(content.toastMessage == String(localized: "toast.folderTree.notAncestor"))
        #expect(fixture.store.grants().isEmpty)
        await tearDown(fixture)
    }

    // ボリュームのルートを開いているときは上位が無いので許可を求めない
    @Test func volumeRootCannotRequestAccess() async throws {
        let fixture = try makeFixture()
        let content = fixture.content

        content.rootFolderURL = URL(fileURLWithPath: "/Volumes/DataDisk", isDirectory: true)
        #expect(!content.canRequestTreeAccess)
        content.rootFolderURL = URL(fileURLWithPath: "/", isDirectory: true)
        #expect(!content.canRequestTreeAccess)
        await tearDown(fixture)
    }

    // 許可すると、ツリーの根が許可したフォルダになり、開いたフォルダまで展開されて該当行が見える
    @Test func grantedTreeRevealsOpenedRoot() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        let sidebar = SidebarViewModel(content: content)
        sidebar.syncFolderTreeRoot()
        await sidebar.folderTree.waitForPendingLoads()
        #expect(sidebar.folderTree.root == FolderTreeViewModel.normalized(fixture.root))

        await content.grantTreeAccess(to: fixture.sandbox)
        sidebar.syncFolderTreeRoot()
        await sidebar.folderTree.waitForPendingLoads()

        let rootRow = FolderTreeViewModel.normalized(fixture.root)
        #expect(sidebar.folderTree.root == FolderTreeViewModel.normalized(fixture.sandbox))
        #expect(sidebar.folderTree.children[FolderTreeViewModel.normalized(fixture.sandbox)]?.contains(rootRow) == true)
        #expect(sidebar.highlightedFolderURL == rootRow)
        #expect(sidebar.folderTree.scrollRequest?.url == rootRow)
        await tearDown(fixture)
    }

    // MARK: - 許可の復元と切替

    // 再起動相当（新しい ViewModel）でも、保存済みの許可をダイアログなしで復元する
    @Test func savedGrantIsRestoredOnNextLaunch() async throws {
        let fixture = try makeFixture()
        await fixture.content.grantTreeAccess(to: fixture.sandbox)

        let relaunched = ContentViewModel()
        let scope = StubTreeAccessScope()
        relaunched.treeAccessStore = fixture.store
        relaunched.treeAccessScope = scope.scope
        relaunched.rootFolderURL = fixture.root
        await relaunched.syncTreeAccess(for: fixture.root)

        let restored = try #require(relaunched.treeAccessURL)
        #expect(FolderPathComponents.isSameFolder(restored, fixture.sandbox))
        #expect(scope.started.count == 1)
        await tearDown(fixture)
    }

    // 同じ許可の範囲内でルートが変わるだけなら、スコープを開き直さない
    @Test func syncKeepsScopeWhileGrantRemainsValid() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.grantTreeAccess(to: fixture.sandbox)

        await content.syncTreeAccess(for: fixture.sibling)

        #expect(content.treeAccessURL != nil)
        #expect(fixture.scope.started.count == 1)
        #expect(fixture.scope.stopped.isEmpty)
        await tearDown(fixture)
    }

    // 別のボリュームを開くと前のスコープを解放し、ルートを根に戻す。保存データは残す
    @Test func syncReleasesScopeForOtherVolume() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.grantTreeAccess(to: fixture.sandbox)
        let granted = try #require(content.treeAccessURL)
        let otherRoot = URL(fileURLWithPath: "/Volumes/DataDisk/photos", isDirectory: true)

        content.rootFolderURL = otherRoot
        await content.syncTreeAccess(for: otherRoot)

        #expect(content.treeAccessURL == nil)
        #expect(content.navigationBoundaryURL == otherRoot)
        #expect(fixture.scope.stopped == [granted])
        #expect(fixture.store.grants().count == 1)
        await tearDown(fixture)
    }

    // 保存済みの "/" の許可は、別ボリュームのツリーの根にしない
    @Test func savedSlashGrantIsNotUsedForOtherVolume() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.store.save(URL(fileURLWithPath: "/", isDirectory: true), bookmark: Data("/".utf8))
        let otherRoot = URL(fileURLWithPath: "/Volumes/DataDisk/photos", isDirectory: true)

        content.rootFolderURL = otherRoot
        await content.syncTreeAccess(for: otherRoot)

        #expect(content.treeAccessURL == nil)
        #expect(fixture.scope.started.isEmpty)
        await tearDown(fixture)
    }

    // 解決先が祖先でなくなっていたら（移動・改名など）使わないが、保存データは消さない
    @Test func resolvedURLOutsideAncestorsIsIgnoredButKept() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.store.save(fixture.sandbox, bookmark: Data(fixture.sandbox.path.utf8))
        fixture.scope.resolvedOverride = fixture.sibling

        await content.syncTreeAccess(for: fixture.root)

        #expect(content.treeAccessURL == nil)
        #expect(content.navigationBoundaryURL == fixture.root)
        #expect(fixture.scope.started.isEmpty)
        #expect(fixture.store.grants().count == 1)
        await tearDown(fixture)
    }

    // stale なら作り直して保存する
    @Test func staleBookmarkIsRefreshed() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.store.save(fixture.sandbox, bookmark: Data(fixture.sandbox.path.utf8))
        fixture.scope.isStale = true

        await content.syncTreeAccess(for: fixture.root)

        #expect(content.treeAccessURL != nil)
        #expect(fixture.scope.bookmarkRequests.value == 1)
        #expect(fixture.store.grants().count == 1)
        await tearDown(fixture)
    }

    // 解決を待っている間に別のルートへ切り替わったら、古い許可のスコープを開始しない
    @Test func syncResultIsDiscardedWhenSupersededDuringResolve() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.store.save(fixture.sandbox, bookmark: Data(fixture.sandbox.path.utf8))
        fixture.scope.resolveGate.close()

        let sync = Task { await content.syncTreeAccess(for: fixture.root) }
        while !fixture.scope.resolveGate.hasEntered { await Task.yield() }
        content.releaseTreeAccess()
        fixture.scope.resolveGate.open()
        await sync.value

        #expect(content.treeAccessURL == nil)
        #expect(fixture.scope.started.isEmpty)
        await tearDown(fixture)
    }

    // 解決待ちの間に同じフォルダが開き直されたら、古い selectFolder は読み込みへ進まない。
    // 表示フォルダが同じなので loadFolderPhotos 側の確認では止まらず、rootEpoch の確認だけが止める
    @Test func supersededSelectFolderDoesNotLoadAgain() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.store.save(fixture.sandbox, bookmark: Data(fixture.sandbox.path.utf8))
        fixture.scope.resolveGate.close()

        let first = Task { await content.selectFolder(url: fixture.sibling) }
        while !fixture.scope.resolveGate.hasEntered { await Task.yield() }
        await content.selectFolder(url: fixture.sibling)
        let generation = content.photoStagingGeneration
        fixture.scope.resolveGate.open()
        await first.value

        #expect(content.photoStagingGeneration == generation)
        #expect(content.currentFolderURL == fixture.sibling)
        #expect(photoNames(content) == ["b1.png"])
        #expect(!content.isLoading)
        #expect(fixture.scope.started.count == 1)
        await tearDown(fixture)
    }

    // restoreFolder も同じ。実際のブックマークを使い、同じ履歴を開き直す
    @Test func supersededRestoreFolderDoesNotLoadAgain() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.store.save(fixture.sandbox, bookmark: Data(fixture.sandbox.path.utf8))
        let bookmark = try fixture.sibling.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let history = FolderHistory(url: fixture.sibling, bookmark: bookmark)
        fixture.context.insert(history)
        fixture.scope.resolveGate.close()

        let first = Task { await content.restoreFolder(history) }
        while !fixture.scope.resolveGate.hasEntered { await Task.yield() }
        await content.restoreFolder(history)
        let generation = content.photoStagingGeneration
        fixture.scope.resolveGate.open()
        await first.value

        #expect(content.error == nil)
        #expect(content.photoStagingGeneration == generation)
        #expect(photoNames(content) == ["b1.png"])
        #expect(!content.isLoading)
        content.releaseBookmarkAccess()
        await tearDown(fixture)
    }

    // 許可の解決を待つ間、新しいルートの下に旧ルートの写真を出さない
    @Test func oldPhotosAreClearedWhileTreeAccessResolves() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.navigateToFolder(fixture.sub)
        content.selectPhoto(content.photos.first)
        #expect(!content.photos.isEmpty)
        #expect(content.selectedPhoto != nil)
        fixture.store.save(fixture.sandbox, bookmark: Data(fixture.sandbox.path.utf8))
        fixture.scope.resolveGate.close()

        let opening = Task { await content.selectFolder(url: fixture.sibling) }
        while !fixture.scope.resolveGate.hasEntered { await Task.yield() }

        #expect(content.rootFolderURL == fixture.sibling)
        #expect(content.photos.isEmpty)
        #expect(content.selectedPhoto == nil)
        #expect(content.isLoading)

        fixture.scope.resolveGate.open()
        await opening.value

        #expect(photoNames(content) == ["b1.png"])
        #expect(!content.isLoading)
        await tearDown(fixture)
    }

    // 解決待ちの間に別のフォルダを開こうとして失敗しても、読み込み中のまま残らない
    @Test func loadingStateIsClearedWhenSupersedingOpenFails() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.store.save(fixture.sandbox, bookmark: Data(fixture.sandbox.path.utf8))
        fixture.scope.resolveGate.close()

        let opening = Task { await content.selectFolder(url: fixture.sibling) }
        while !fixture.scope.resolveGate.hasEntered { await Task.yield() }
        #expect(content.isLoading)
        await content.selectFolder(url: fixture.sandbox.appendingPathComponent("missing", isDirectory: true))
        fixture.scope.resolveGate.open()
        await opening.value

        #expect(content.rootFolderURL == nil)
        #expect(!content.isLoading)
        await tearDown(fixture)
    }

    // 古い読み込み要求は、切り替わった後の表示フォルダの一覧を奪わない
    @Test func loadRequestForNonCurrentFolderIsIgnored() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.navigateToFolder(fixture.sub)

        await content.loadFolderPhotos(fixture.grandchild)

        #expect(photoNames(content) == ["s1.png", "s2.png"])
        await tearDown(fixture)
    }

    // フォルダ表示を閉じるときは許可のスコープも解放する（ルートが nil の間は持たない前提のため）
    @Test func failedSelectFolderReleasesTreeAccess() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.grantTreeAccess(to: fixture.sandbox)
        let granted = try #require(content.treeAccessURL)

        await content.selectFolder(url: fixture.sandbox.appendingPathComponent("missing", isDirectory: true))

        #expect(content.rootFolderURL == nil)
        #expect(content.treeAccessURL == nil)
        #expect(fixture.scope.stopped == [granted])
        await tearDown(fixture)
    }

    // MARK: - 許可の解除

    // 兄弟フォルダの表示中に解除すると、ルートへ戻してからスコープを止める。再起動後も残らない
    @Test func revokeReturnsToRootBeforeReleasing() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.grantTreeAccess(to: fixture.sandbox)
        let granted = try #require(content.treeAccessURL)
        await content.navigateToFolder(fixture.sibling)
        #expect(photoNames(content) == ["b1.png"])

        await content.revokeTreeAccess()

        #expect(content.treeAccessURL == nil)
        #expect(content.navigationBoundaryURL == fixture.root)
        #expect(content.currentFolderURL == fixture.root)
        #expect(photoNames(content) == ["r1.png"])
        #expect(fixture.scope.stopped == [granted])
        #expect(fixture.scope.stateAtStop.count == 1)
        #expect(fixture.scope.stateAtStop.first?.folder == fixture.root)
        #expect(fixture.scope.stateAtStop.first?.photoNames == ["r1.png"])
        #expect(fixture.store.grants().isEmpty)

        let relaunched = ContentViewModel()
        relaunched.treeAccessStore = fixture.store
        relaunched.treeAccessScope = fixture.scope.scope
        await relaunched.syncTreeAccess(for: fixture.root)
        #expect(relaunched.treeAccessURL == nil)
        await tearDown(fixture)
    }

    // 表示中のフォルダが範囲内なら読み込み直さない
    @Test func revokeInsideRootDoesNotReload() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.navigateToFolder(fixture.sub)
        await content.grantTreeAccess(to: fixture.sandbox)
        let photosBefore = content.photos.map(\.id)

        await content.revokeTreeAccess()

        #expect(content.currentFolderURL == fixture.sub)
        #expect(content.photos.map(\.id) == photosBefore)
        #expect(fixture.scope.stopped.count == 1)
        await tearDown(fixture)
    }

    // MARK: - 上位フォルダのパネルの自動表示

    // 許可の無いフォルダを開くとパネルが自動で出て、選んだ上位フォルダが許可になる
    @Test func openingFolderPromptsForAncestorAndGrantsSelection() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.prompt.selection = fixture.sandbox

        await content.selectFolder(url: fixture.sibling)
        await content.treeAccessPromptTask?.value

        #expect(fixture.prompt.requestedRoots == [fixture.sibling])
        #expect(FolderPathComponents.isSameFolder(try #require(content.treeAccessURL), fixture.sandbox))
        #expect(fixture.store.grants().count == 1)
        #expect(content.rootFolderURL == fixture.sibling)
        await tearDown(fixture)
    }

    // キャンセルしたボリュームでは、別のフォルダを開いてもパネルを出し直さない
    @Test func cancelledPromptIsNotShownAgainOnSameVolume() async throws {
        let fixture = try makeFixture()
        let content = fixture.content

        await content.selectFolder(url: fixture.sibling)
        await content.treeAccessPromptTask?.value
        await content.selectFolder(url: fixture.root)
        await content.treeAccessPromptTask?.value

        #expect(fixture.prompt.requestedRoots == [fixture.sibling])
        #expect(content.treeAccessURL == nil)
        #expect(fixture.store.grants().isEmpty)
        await tearDown(fixture)
    }

    // 保存済みの許可で上位が表示できるときはパネルを出さない
    @Test func savedGrantSuppressesPrompt() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        fixture.store.save(fixture.sandbox, bookmark: Data(fixture.sandbox.path.utf8))

        await content.selectFolder(url: fixture.sibling)
        await content.treeAccessPromptTask?.value

        #expect(fixture.prompt.requestedRoots.isEmpty)
        #expect(FolderPathComponents.isSameFolder(try #require(content.treeAccessURL), fixture.sandbox))
        await tearDown(fixture)
    }

    // 許可を解除した後に同じボリュームのフォルダを開いても、パネルを出し直さない
    @Test func revokedVolumeIsNotPromptedAgain() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        await content.grantTreeAccess(to: fixture.sandbox)
        await content.revokeTreeAccess()

        await content.selectFolder(url: fixture.sibling)
        await content.treeAccessPromptTask?.value

        #expect(fixture.prompt.requestedRoots.isEmpty)
        #expect(content.treeAccessURL == nil)
        await tearDown(fixture)
    }

    // パネル表示中に別のルートへ切り替わったら、旧ルート向けの選択は使わない
    @Test func promptResultIsDiscardedWhenRootChanges() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        content.treeAccessPrompt = { [content, fixture] _ in
            content.rootFolderURL = fixture.root
            return fixture.sandbox
        }

        await content.selectFolder(url: fixture.sibling)
        await content.treeAccessPromptTask?.value

        #expect(content.treeAccessURL == nil)
        #expect(fixture.store.grants().isEmpty)
        await tearDown(fixture)
    }

    // MARK: - 古いクリックの破棄

    // デバウンス中のクリックの直後に別のフォルダを開くと、新しく開いたフォルダが表示される
    @Test func debouncedClickDoesNotOverrideNewlyOpenedFolder() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        let sidebar = SidebarViewModel(content: content)
        content.treeAccessURL = fixture.sandbox
        sidebar.syncFolderTreeRoot()
        await sidebar.folderTree.waitForPendingLoads()

        sidebar.folderTree.requestNavigate(fixture.sub)
        await content.selectFolder(url: fixture.sibling)
        await sidebar.folderTree.waitForPendingNavigation()

        #expect(content.error == nil)
        #expect(content.rootFolderURL == fixture.sibling)
        #expect(content.currentFolderURL == fixture.sibling)
        #expect(photoNames(content) == ["b1.png"])
        #expect(sidebar.folderTree.pendingSelection == nil)
        await tearDown(fixture)
    }
}
