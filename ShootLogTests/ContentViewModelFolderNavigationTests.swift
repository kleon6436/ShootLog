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

        content.rootFolderURL = root
        content.currentFolderURL = root
        content.currentPhotoSource = .folder(root)
        return Fixture(content: content, context: context, sandbox: sandbox, root: root, sub: sub, grandchild: grandchild)
    }

    // 後片付け。バックグラウンドの生成処理を止めてから作業ディレクトリを消す
    private func tearDown(_ fixture: Fixture) async {
        await fixture.content.cancelPhotoStaging()
        try? FileManager.default.removeItem(at: fixture.sandbox)
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
}
