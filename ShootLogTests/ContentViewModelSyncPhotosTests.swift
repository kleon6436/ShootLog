import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

// syncPhotos がフォルダの URL の分だけを引くようになったことによる回帰テスト。
// 同じ URL の Photo が重複して作られないこと、別フォルダの写真の行を再利用することを確かめる
@MainActor
struct ContentViewModelSyncPhotosTests {
    // initialPhotoBatchSize（50）を超え、段階挿入（100件ずつ）が複数回走る枚数
    static let photoCount = 260

    private struct Fixture {
        let content: ContentViewModel
        let context: ModelContext
        let sandbox: URL
        let folder: URL
        let urls: [URL]
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
            .appendingPathComponent("SyncPhotosTests-\(UUID().uuidString)", isDirectory: true)
        let folder = sandbox.appendingPathComponent("写真 フォルダ", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = try Self.pngData()
        for index in 0..<Self.photoCount {
            try png.write(to: folder.appendingPathComponent(String(format: "IMG_%04d.png", index)))
        }
        let urls = try PhotoRepository.scanImageURLs(in: folder).urls
        content.rootFolderURL = folder
        content.currentFolderURL = folder
        content.currentPhotoSource = .folder(folder)
        return Fixture(content: content, context: context, sandbox: sandbox, folder: folder, urls: urls)
    }

    private func tearDown(_ fixture: Fixture) async {
        await fixture.content.cancelPhotoStaging()
        try? FileManager.default.removeItem(at: fixture.sandbox)
    }

    private static func pngData() throws -> Data {
        let width = 4
        let height = 4
        let pixels = [UInt8](repeating: 200, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // フォルダ内の各 URL について、ストアに Photo が何行あるか
    private func rowCounts(_ fixture: Fixture) throws -> [URL: Int] {
        let rows = try fixture.context.fetch(FetchDescriptor<Photo>())
        return Dictionary(grouping: rows, by: \.fileURL).mapValues(\.count)
    }

    private func waitForStaging(_ content: ContentViewModel) async {
        await content.photoStagingTask?.value
    }

    @Test func reopeningAfterCancelledStagingDoesNotDuplicatePhotos() async throws {
        let fixture = try makeFixture()
        let content = fixture.content

        await content.loadFolderPhotos(fixture.folder)
        // 先頭の50件だけ挿入された時点で段階挿入を打ち切る（未保存の行が残りうる経路）
        await content.cancelPhotoStaging()
        await content.loadFolderPhotos(fixture.folder)
        await waitForStaging(content)

        let counts = try rowCounts(fixture)
        #expect(content.photos.count == Self.photoCount)
        #expect(Set(content.photos.map(\.fileURL)) == Set(fixture.urls))
        #expect(fixture.urls.allSatisfy { counts[$0] == 1 })
        await tearDown(fixture)
    }

    @Test func switchingFoldersTwiceQuicklyDoesNotDuplicatePhotos() async throws {
        let fixture = try makeFixture()
        let content = fixture.content

        // 2回目の読み込みを1回目の完了を待たずに始める（フォルダを素早く2回切り替えた状態）
        let folder = fixture.folder
        let first = Task { await content.loadFolderPhotos(folder) }
        let second = Task { await content.loadFolderPhotos(folder) }
        await first.value
        await second.value
        await waitForStaging(content)
        // もう一度開き直しても行は増えない
        await content.loadFolderPhotos(fixture.folder)
        await waitForStaging(content)

        let counts = try rowCounts(fixture)
        #expect(fixture.urls.allSatisfy { counts[$0] == 1 })
        #expect(content.photos.count == Self.photoCount)
        await tearDown(fixture)
    }

    // 既存の行（別フォルダを開いたときに作られたもの・編集情報を持つもの）を作り直さずに再利用する
    @Test func reusesExistingPhotoRowsAndIgnoresOtherFolders() async throws {
        let fixture = try makeFixture()
        let content = fixture.content
        let reused = Photo(fileURL: fixture.urls[10])
        reused.isFavorite = true
        fixture.context.insert(reused)
        for index in 0..<500 {
            fixture.context.insert(Photo(fileURL: URL(fileURLWithPath: "/tmp/other/\(index).jpg")))
        }
        try fixture.context.save()

        await content.loadFolderPhotos(fixture.folder)
        await waitForStaging(content)

        #expect(content.photos.contains { $0.persistentModelID == reused.persistentModelID })
        #expect(content.photos.first { $0.fileURL == fixture.urls[10] }?.isFavorite == true)
        #expect(content.photos.allSatisfy { $0.fileURL.deletingLastPathComponent().lastPathComponent == "写真 フォルダ" })
        #expect(try rowCounts(fixture)[fixture.urls[10]] == 1)
        await tearDown(fixture)
    }
}
