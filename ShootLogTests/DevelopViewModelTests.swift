import CoreGraphics
import Foundation
import SwiftData
import Testing

@testable import ShootLog

@MainActor
struct DevelopViewModelTests {

    // MARK: - スパイエンジン

    final class SpyEngine: ImageDeveloping, @unchecked Sendable {
        private let lock = NSLock()
        private var previewCalls = 0
        private var lastParams: DevelopParameters?
        var rawFileNames: Set<String> = []
        var stub: CGImage?

        var previewCallCount: Int { lock.withLock { previewCalls } }
        var lastParameters: DevelopParameters? { lock.withLock { lastParams } }

        func renderPreview(
            url: URL,
            parameters: DevelopParameters,
            targetMaxPixelSize: CGFloat
        ) async -> CGImage? {
            lock.withLock {
                previewCalls += 1
                lastParams = parameters
            }
            return stub
        }

        func renderFull(url: URL, parameters: DevelopParameters) async -> CGImage? { stub }

        func isRAW(url: URL) -> Bool { rawFileNames.contains(url.lastPathComponent) }
    }

    // MARK: - ヘルパー

    private func makeStubImage() -> CGImage? {
        let width = 4, height = 4
        var pixels = [UInt8](repeating: 180, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private func makeContentViewModel() throws -> (ContentViewModel, ModelContext, Photo) {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/develop-vm-test.jpg"))
        context.insert(photo)
        try context.save()

        let content = ContentViewModel()
        content.modelContext = context
        content.selectedPhoto = photo
        return (content, context, photo)
    }

    private func makeViewModel(
        engine: SpyEngine,
        content: ContentViewModel? = nil
    ) -> DevelopViewModel {
        DevelopViewModel(
            engine: engine,
            content: content,
            renderDebounce: .milliseconds(5),
            persistDebounce: .milliseconds(10)
        )
    }

    private func settle(_ milliseconds: UInt64 = 60) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: - テスト

    @Test func neutralLoadDoesNotCallEngine() async throws {
        let engine = SpyEngine()
        let vm = makeViewModel(engine: engine)
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))

        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(engine.previewCallCount == 0)
        #expect(vm.previewImage == nil)
    }

    @Test func changingParametersRendersAfterDebounce() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var params = DevelopParameters.neutral
        params.exposure = 1.0
        vm.parameters = params
        await settle()

        #expect(engine.previewCallCount == 1)
        #expect(engine.lastParameters?.exposure == 1.0)
        #expect(vm.previewImage != nil)
        #expect(vm.histogram != nil)
        #expect(vm.isRendering == false)
    }

    @Test func rapidChangesCoalesceToOneRender() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        for value in stride(from: 0.1, through: 0.5, by: 0.1) {
            var params = DevelopParameters.neutral
            params.exposure = value
            vm.parameters = params
        }
        await settle()

        #expect(engine.previewCallCount == 1)
        #expect(engine.lastParameters?.exposure == 0.5)
    }

    @Test func resetReturnsToNeutralAndClearsPreview() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var params = DevelopParameters.neutral
        params.contrast = 30
        vm.parameters = params
        await settle()
        #expect(vm.previewImage != nil)

        vm.reset()

        #expect(vm.parameters == .neutral)
        #expect(vm.previewImage == nil)
        #expect(vm.histogram == nil)
        #expect(vm.canReset == false)
    }

    @Test func loadPullsPersistedParametersAndRenders() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, photo) = try makeContentViewModel()

        let saved = DevelopSettings(photoID: photo.id)
        var params = DevelopParameters.neutral
        params.vibrance = 55
        saved.parameters = params
        context.insert(saved)
        try context.save()
        content.currentDevelopSettings = saved

        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(vm.parameters.vibrance == 55)
        #expect(engine.previewCallCount == 1)
    }

    @Test func editsPersistThroughContentViewModelAfterDebounce() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, photo) = try makeContentViewModel()

        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))

        var params = DevelopParameters.neutral
        params.saturation = 20
        vm.parameters = params
        await settle(120)

        let rows = try context.fetch(FetchDescriptor<DevelopSettings>())
        #expect(rows.count == 1)
        #expect(rows.first?.parameters.saturation == 20)
        #expect(rows.first?.photoID == photo.id)
    }

    @Test func isRAWReflectsEngine() async throws {
        let engine = SpyEngine()
        engine.rawFileNames = ["shot.nef"]
        let vm = makeViewModel(engine: engine)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/shot.nef")), displaySize: .zero)
        #expect(vm.isRAW == true)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/shot.jpg")), displaySize: .zero)
        #expect(vm.isRAW == false)
    }

    @Test func switchingPhotoDiscardsStalePreview() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        var params = DevelopParameters.neutral
        params.exposure = 1.0
        vm.parameters = params

        // デバウンス満了前に別写真へ切り替え（中立）
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/b.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(vm.parameters == .neutral)
        #expect(vm.previewImage == nil)
    }
}
