import CoreGraphics
import Foundation
import SwiftData
import Testing

@testable import ShootLog

// 書き出しジョブの入力（フォルダ・写真一覧・回転・トリミング）を開始時点で固定する検証。
// 実行中にサブフォルダへ移動して currentFolderURL / photos が変わっても、
// 保存先の検証（防御1・防御2）が開始時点の値を基準に効くことを確かめる
@MainActor
struct ContentViewModelExportInputTests {

    private struct Fixture {
        let content: ContentViewModel
        let context: ModelContext
        let sandbox: URL
        // 書き出し開始時に開いていたフォルダ
        let startFolder: URL
        // 書き出し中に移動した先のフォルダ
        let movedFolder: URL
    }

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
            .appendingPathComponent("ExportInputTests-\(UUID().uuidString)", isDirectory: true)
        let startFolder = sandbox.appendingPathComponent("start", isDirectory: true)
        let movedFolder = startFolder.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: movedFolder, withIntermediateDirectories: true)
        return Fixture(
            content: content, context: context, sandbox: sandbox,
            startFolder: startFolder, movedFolder: movedFolder
        )
    }

    private func makePhoto(at url: URL, in context: ModelContext) throws -> Photo {
        try Data("x".utf8).write(to: url)
        let photo = Photo(fileURL: url)
        context.insert(photo)
        return photo
    }

    // 開始後に表示フォルダと写真一覧が差し替わった状態を作る
    private func simulateNavigation(_ fixture: Fixture) {
        fixture.content.currentFolderURL = fixture.movedFolder
        fixture.content.photos = []
    }

    // MARK: - 超解像

    @Test func upscaleValidatesAgainstStartFolderAfterNavigation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let photo = try makePhoto(at: fixture.startFolder.appendingPathComponent("a.png"), in: fixture.context)
        let input = ContentViewModel.UpscaleExportInput(
            currentFolder: fixture.startFolder,
            folderPhotoURLs: [photo.fileURL],
            rotation: 0,
            cropRect: nil
        )
        simulateNavigation(fixture)
        let viewModel = UpscaleExportViewModel(inputPixelSize: CGSize(width: 8, height: 8))
        viewModel.engineKind = .traditional

        // 防御1: 開始時のフォルダへの保存は、表示フォルダが変わっていても拒否される
        await fixture.content.runUpscaleExport(
            photo: photo,
            destination: fixture.startFolder.appendingPathComponent("out.png"),
            input: input,
            viewModel: viewModel
        )

        guard case .failed(.superResolutionDestinationInSourceFolder) = viewModel.state else {
            Issue.record("開始時のフォルダを基準に防御1が効いていない: \(viewModel.state)")
            return
        }
    }

    @Test func upscaleProtectsStartPhotosAfterNavigation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        // 開始時の写真一覧にある原本を、別フォルダ（防御1の対象外）から上書きしようとする
        let other = fixture.sandbox.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let original = try makePhoto(at: other.appendingPathComponent("b.png"), in: fixture.context)
        let input = ContentViewModel.UpscaleExportInput(
            currentFolder: fixture.startFolder,
            folderPhotoURLs: [original.fileURL],
            rotation: 0,
            cropRect: nil
        )
        simulateNavigation(fixture)
        let viewModel = UpscaleExportViewModel(inputPixelSize: CGSize(width: 8, height: 8))
        viewModel.engineKind = .traditional

        await fixture.content.runUpscaleExport(
            photo: original,
            destination: original.fileURL,
            input: input,
            viewModel: viewModel
        )

        guard case .failed(.superResolutionOverwritesOriginal) = viewModel.state else {
            Issue.record("開始時の写真一覧を基準に防御2が効いていない: \(viewModel.state)")
            return
        }
    }

    // MARK: - 現像

    @Test func developInputIsCapturedAtStart() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let photo = try makePhoto(at: fixture.startFolder.appendingPathComponent("a.png"), in: fixture.context)
        fixture.content.currentFolderURL = fixture.startFolder
        fixture.content.photos = [photo]

        let input = fixture.content.makeDevelopExportInput(for: photo)
        simulateNavigation(fixture)

        #expect(input.currentFolder == fixture.startFolder)
        #expect(input.folderPhotoURLs == [photo.fileURL])

        let viewModel = DevelopExportViewModel()
        await fixture.content.runDevelopExport(
            photo: photo,
            destination: fixture.startFolder.appendingPathComponent("out.jpg"),
            input: input,
            viewModel: viewModel
        )

        guard case .failed(.superResolutionDestinationInSourceFolder) = viewModel.state else {
            Issue.record("開始時のフォルダを基準に防御1が効いていない: \(viewModel.state)")
            return
        }
    }
}
