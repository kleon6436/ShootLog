import Foundation
import SwiftData
import Testing

@testable import ShootLog

@MainActor
struct ContentViewModelPasteboardTests {

    // 実際の NSPasteboard を汚さないためのスタブ
    final class SpyPasteboardWriter: PhotoPasteboardWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        private var urls: [URL] = []

        var writtenTexts: [String] { lock.withLock { texts } }
        var writtenURLs: [URL] { lock.withLock { urls } }

        func writeText(_ text: String) { lock.withLock { texts.append(text) } }
        func writeFileURL(_ url: URL) { lock.withLock { urls.append(url) } }
    }

    private func makeContentViewModel(
        writer: SpyPasteboardWriter
    ) throws -> (ContentViewModel, ModelContext) {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let content = ContentViewModel()
        content.modelContext = context
        content.pasteboardWriter = writer
        return (content, context)
    }

    @Test func copiesDisplayFileNameAndShowsToast() throws {
        let writer = SpyPasteboardWriter()
        let (content, context) = try makeContentViewModel(writer: writer)
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/ShootLogTests/IMG_0001.NEF"))
        context.insert(photo)
        // EXIF 遅延ロードなどの副作用を避けるため選択状態だけを直接組み立てる
        content.selectedPhoto = photo

        content.copyFileNameToPasteboard()

        #expect(writer.writtenTexts == ["IMG_0001.NEF"])
        #expect(content.toastMessage == String(localized: "toast.copied.fileName"))
    }

    @Test func copiesFilePathForFolderPhoto() throws {
        let writer = SpyPasteboardWriter()
        let (content, context) = try makeContentViewModel(writer: writer)
        let url = URL(fileURLWithPath: "/tmp/ShootLogTests/IMG_0001.NEF")
        let photo = Photo(fileURL: url)
        context.insert(photo)
        // EXIF 遅延ロードなどの副作用を避けるため選択状態だけを直接組み立てる
        content.selectedPhoto = photo

        content.copyFilePathToPasteboard()

        #expect(writer.writtenURLs == [url])
        #expect(content.toastMessage == String(localized: "toast.copied.path"))
    }

    @Test func doesNotCopyPathForPhotosLibraryPhoto() throws {
        let writer = SpyPasteboardWriter()
        let (content, context) = try makeContentViewModel(writer: writer)
        let photo = Photo(
            fileURL: URL(fileURLWithPath: "/tmp/ShootLogTests/icloud-import-v2/ABC123_L0_001.jpg"),
            phAssetLocalIdentifier: "ABC123/L0/001"
        )
        context.insert(photo)
        // EXIF 遅延ロードなどの副作用を避けるため選択状態だけを直接組み立てる
        content.selectedPhoto = photo

        content.copyFilePathToPasteboard()

        #expect(writer.writtenURLs.isEmpty)
        #expect(content.toastMessage == nil)
    }
}
