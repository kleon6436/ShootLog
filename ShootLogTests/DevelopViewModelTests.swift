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
        private var lastRotationValue = 0
        private var lastCropValue: CGRect?
        private var lastRAWMappingValue = false
        var rawFileNames: Set<String> = []
        var stub: CGImage?

        var previewCallCount: Int { lock.withLock { previewCalls } }
        var lastParameters: DevelopParameters? { lock.withLock { lastParams } }
        var lastRotation: Int { lock.withLock { lastRotationValue } }
        var lastCropRect: CGRect? { lock.withLock { lastCropValue } }
        var lastRAWMapping: Bool { lock.withLock { lastRAWMappingValue } }

        func renderPreview(
            url: URL,
            parameters: DevelopParameters,
            targetMaxPixelSize: CGFloat,
            rotation: Int,
            cropRect: CGRect?,
            useRAWParameterMapping: Bool
        ) async -> CGImage? {
            lock.withLock {
                previewCalls += 1
                lastParams = parameters
                lastRotationValue = rotation
                lastCropValue = cropRect
                lastRAWMappingValue = useRAWParameterMapping
            }
            return stub
        }

        func renderFull(
            url: URL,
            parameters: DevelopParameters,
            rotation: Int,
            cropRect: CGRect?,
            outputColorSpace: CGColorSpace?,
            useRAWParameterMapping: Bool
        ) async -> CGImage? { stub }

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

    @Test func switchingPhotoFlushesPendingPersist() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, photoA) = try makeContentViewModel()
        let photoB = Photo(fileURL: URL(fileURLWithPath: "/tmp/b.jpg"))
        context.insert(photoB)
        try context.save()

        // 保存デバウンスは長め、描画は短めにして「保存前に写真を切り替える」状況を作る。
        let vm = DevelopViewModel(
            engine: engine, content: content,
            renderDebounce: .milliseconds(5), persistDebounce: .milliseconds(500)
        )
        vm.load(photo: photoA, displaySize: CGSize(width: 800, height: 600))

        var params = DevelopParameters.neutral
        params.exposure = 1.75
        vm.parameters = params
        await settle(40)   // 保存デバウンス(500ms)満了前

        content.selectedPhoto = photoB
        content.loadDevelopSettings(for: photoB)
        vm.load(photo: photoB, displaySize: CGSize(width: 800, height: 600))
        await settle(40)

        let rows = try context.fetch(FetchDescriptor<DevelopSettings>())
        let rowA = rows.first { $0.photoID == photoA.id }
        #expect(rowA?.parameters.exposure == 1.75)
    }

    @Test func failedRenderClearsStalePreview() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var params = DevelopParameters.neutral
        params.contrast = 30
        vm.parameters = params
        await settle()
        #expect(vm.previewImage != nil)

        // 次のレンダーは失敗（stub = nil）。古いプレビューを残さない。
        engine.stub = nil
        params.contrast = 60
        vm.parameters = params
        await settle()

        #expect(vm.previewImage == nil)
        #expect(vm.histogram == nil)
        #expect(vm.isRendering == false)
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

    // MARK: - 回転・トリミングのライブプレビュー

    @Test func neutralParametersButRotationStillRenders() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)

        vm.load(
            photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")),
            displaySize: CGSize(width: 800, height: 600),
            rotation: 90,
            cropRect: nil
        )
        await settle()

        #expect(engine.previewCallCount == 1)
        #expect(engine.lastRotation == 90)
        #expect(vm.previewImage != nil)
    }

    @Test func neutralParametersAndNoGeometryDoesNotRender() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)

        // 全体矩形は実質トリミングなし。回転も無し → レンダーしない。
        vm.load(
            photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")),
            displaySize: CGSize(width: 800, height: 600),
            rotation: 0,
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        await settle()

        #expect(engine.previewCallCount == 0)
        #expect(vm.previewImage == nil)
    }

    @Test func updateEditGeometryTriggersRenderWithCrop() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()
        #expect(engine.previewCallCount == 0)

        let crop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        vm.updateEditGeometry(rotation: 0, cropRect: crop)
        await settle()

        #expect(engine.previewCallCount == 1)
        #expect(engine.lastCropRect == crop)
        #expect(vm.previewImage != nil)
    }

    @Test func clearingGeometryWhileNeutralClearsPreview() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(
            photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")),
            displaySize: CGSize(width: 800, height: 600),
            rotation: 90
        )
        await settle()
        #expect(vm.previewImage != nil)

        vm.updateEditGeometry(rotation: 0, cropRect: nil)
        await settle()

        #expect(vm.previewImage == nil)
        #expect(vm.histogram == nil)
    }

    @Test func staleRotationResultIsDiscarded() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(
            photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")),
            displaySize: CGSize(width: 800, height: 600),
            rotation: 90
        )
        // デバウンス満了前に回転を変える。古い回転の結果で上書きされないこと。
        vm.updateEditGeometry(rotation: 180, cropRect: nil)
        await settle()

        #expect(engine.lastRotation == 180)
    }

    // MARK: - プリセット / コピー & ペースト / Undo

    @Test func applyPresetReplacesParametersAndSchedulesRenderAndPersist() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, photo) = try makeContentViewModel()
        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))

        var params = DevelopParameters.neutral
        params.exposure = 1.25
        let preset = DevelopPreset(name: "P", parameters: params, sortIndex: 0)

        vm.applyPreset(preset)
        #expect(vm.parameters.exposure == 1.25)
        #expect(vm.canUndo)

        await settle(120)
        #expect(engine.previewCallCount == 1)
        let rows = try context.fetch(FetchDescriptor<DevelopSettings>())
        #expect(rows.first?.parameters.exposure == 1.25)
    }

    @Test func undoRestoresParametersBeforeApply() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var start = DevelopParameters.neutral
        start.contrast = 10
        vm.parameters = start
        await settle()

        var presetParams = DevelopParameters.neutral
        presetParams.contrast = 90
        vm.applyPreset(DevelopPreset(name: "P", parameters: presetParams, sortIndex: 0))
        #expect(vm.parameters.contrast == 90)

        vm.undoLastApply()
        #expect(vm.parameters.contrast == 10)
        #expect(vm.canUndo == false)
    }

    @Test func copyThenPasteMovesAdjustments() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var params = DevelopParameters.neutral
        params.saturation = 33
        vm.parameters = params
        await settle()

        vm.copyAdjustments()
        #expect(vm.canPaste)

        vm.reset()
        #expect(vm.parameters == .neutral)

        vm.pasteAdjustments()
        #expect(vm.parameters.saturation == 33)
        #expect(vm.canUndo)
    }

    // MARK: - RAW 露出・WB の CIRAWFilter 委譲

    private func makeRAWContentViewModel(
        schemaVersion: Int?
    ) throws -> (ContentViewModel, ModelContext, Photo) {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/shot.nef"))
        context.insert(photo)

        if let schemaVersion {
            let settings = DevelopSettings(photoID: photo.id)
            settings.schemaVersion = schemaVersion
            var params = DevelopParameters.neutral
            params.exposure = 0.5
            settings.parameters = params
            context.insert(settings)
            try context.save()
        }

        let content = ContentViewModel()
        content.modelContext = context
        content.selectedPhoto = photo
        content.loadDevelopSettings(for: photo)
        return (content, context, photo)
    }

    @Test func rawWithVersion2RendersWithMapping() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.rawFileNames = ["shot.nef"]
        let (content, _, photo) = try makeRAWContentViewModel(schemaVersion: 2)

        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(engine.previewCallCount >= 1)
        #expect(engine.lastRAWMapping == true)
        #expect(vm.canDelegateToRAWFilter)
    }

    @Test func rawWithLegacyVersion1RendersWithoutMapping() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.rawFileNames = ["shot.nef"]
        let (content, _, photo) = try makeRAWContentViewModel(schemaVersion: 1)

        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(engine.previewCallCount >= 1)
        #expect(engine.lastRAWMapping == false)
        #expect(vm.canDelegateToRAWFilter == false)
    }

    @Test func nonRAWNeverUsesMapping() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var params = DevelopParameters.neutral
        params.exposure = 1.0
        vm.parameters = params
        await settle()

        #expect(engine.lastRAWMapping == false)
        #expect(vm.canDelegateToRAWFilter == false)
    }

    @Test func draggingRAWParameterSuppressesMappingUntilRelease() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.rawFileNames = ["shot.nef"]
        let (content, _, photo) = try makeRAWContentViewModel(schemaVersion: 2)

        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        vm.setRAWParameterDragging(true)
        var params = vm.parameters
        params.exposure = 1.5
        vm.parameters = params
        await settle()
        #expect(engine.lastRAWMapping == false)   // ドラッグ中は近似

        vm.setRAWParameterDragging(false)
        await settle(220)
        #expect(engine.lastRAWMapping == true)    // 離したら CIRAWFilter 経路で描き直す
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
