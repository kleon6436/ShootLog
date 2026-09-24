import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

/// DevelopViewModel のテスト群が共有するスパイとヘルパー。
/// 各テスト struct はこのプロトコルへ準拠するだけで、従来どおり `SpyEngine` や
/// `makeViewModel` を修飾なしで使える。
@MainActor
protocol DevelopViewModelTesting {}

// MARK: - スパイエンジン

final class DevelopViewModelSpyEngine: ImageDeveloping, @unchecked Sendable {
    private let lock = NSLock()
    private var previewCalls = 0
    private var neutralPreviewCalls = 0
    private var lastParams: DevelopParameters?
    private var lastRotationValue = 0
    private var lastCropValue: CGRect?
    private var lastRAWMappingValue = false
    private var lastUsesManualLensCorrectionValue = false
    private var lastUsesToneMaskedColorGradingValue = false
    private var lastAsShotWhiteBalanceValue: WhiteBalanceSample?
    private var previewDelayMilliseconds = 0
    private var asShotDelayMilliseconds = 0
    var rawFileNames: Set<String> = []
    var stub: CGImage?
    var asShotStub: WhiteBalanceSample? = nil

    var previewCallCount: Int { lock.withLock { previewCalls } }
    var neutralPreviewCallCount: Int { lock.withLock { neutralPreviewCalls } }
    var lastParameters: DevelopParameters? { lock.withLock { lastParams } }
    var lastRotation: Int { lock.withLock { lastRotationValue } }
    var lastCropRect: CGRect? { lock.withLock { lastCropValue } }
    var lastRAWMapping: Bool { lock.withLock { lastRAWMappingValue } }
    var lastUsesManualLensCorrection: Bool { lock.withLock { lastUsesManualLensCorrectionValue } }
    var lastUsesToneMaskedColorGrading: Bool { lock.withLock { lastUsesToneMaskedColorGradingValue } }
    var lastAsShotWhiteBalance: WhiteBalanceSample? { lock.withLock { lastAsShotWhiteBalanceValue } }
    var previewDelay: Int {
        get { lock.withLock { previewDelayMilliseconds } }
        set { lock.withLock { previewDelayMilliseconds = newValue } }
    }
    var asShotDelay: Int {
        get { lock.withLock { asShotDelayMilliseconds } }
        set { lock.withLock { asShotDelayMilliseconds = newValue } }
    }

    private var lastPreviewColorSpaceValue: CGColorSpace?
    var lastPreviewColorSpace: CGColorSpace? { lock.withLock { lastPreviewColorSpaceValue } }

    private var lastMaskRastersValue: [UUID: CGImage] = [:]
    var lastMaskRasters: [UUID: CGImage] { lock.withLock { lastMaskRastersValue } }

    private var maskOverlayCalls = 0
    private var lastMaskOverlayParams: DevelopParameters?
    var maskOverlayStub: CGImage?
    var maskOverlayCallCount: Int { lock.withLock { maskOverlayCalls } }
    var lastMaskOverlayParameters: DevelopParameters? { lock.withLock { lastMaskOverlayParams } }

    func renderMaskOverlay(
        url: URL,
        parameters: DevelopParameters,
        targetMaxPixelSize: CGFloat,
        rotation: Int,
        cropRect: CGRect?,
        useRAWParameterMapping: Bool,
        maskRasters: [UUID: CGImage]
    ) async -> CGImage? {
        lock.withLock {
            maskOverlayCalls += 1
            lastMaskOverlayParams = parameters
        }
        return maskOverlayStub
    }

    func renderPreview(
        url: URL,
        parameters: DevelopParameters,
        targetMaxPixelSize: CGFloat,
        rotation: Int,
        cropRect: CGRect?,
        previewColorSpace: CGColorSpace?,
        useRAWParameterMapping: Bool,
        usesManualLensCorrection: Bool,
        usesToneMaskedColorGrading: Bool,
        asShotWhiteBalance: WhiteBalanceSample?,
        maskRasters: [UUID: CGImage]
    ) async -> CGImage? {
        let delay = lock.withLock { previewDelayMilliseconds }
        if delay > 0 {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        lock.withLock {
            previewCalls += 1
            if parameters.isNeutral {
                neutralPreviewCalls += 1
            }
            lastParams = parameters
            lastRotationValue = rotation
            lastCropValue = cropRect
            lastPreviewColorSpaceValue = previewColorSpace
            lastRAWMappingValue = useRAWParameterMapping
            lastUsesManualLensCorrectionValue = usesManualLensCorrection
            lastUsesToneMaskedColorGradingValue = usesToneMaskedColorGrading
            lastAsShotWhiteBalanceValue = asShotWhiteBalance
            lastMaskRastersValue = maskRasters
        }
        return stub
    }

    func renderFull(
        url: URL,
        parameters: DevelopParameters,
        rotation: Int,
        cropRect: CGRect?,
        outputColorSpace: CGColorSpace?,
        useRAWParameterMapping: Bool,
        usesManualLensCorrection: Bool,
        usesToneMaskedColorGrading: Bool,
        asShotWhiteBalance: WhiteBalanceSample?,
        maskRasters: [UUID: CGImage]
    ) async -> CGImage? {
        lock.withLock {
            lastUsesManualLensCorrectionValue = usesManualLensCorrection
            lastUsesToneMaskedColorGradingValue = usesToneMaskedColorGrading
            lastAsShotWhiteBalanceValue = asShotWhiteBalance
        }
        return stub
    }

    func isRAW(url: URL) -> Bool { rawFileNames.contains(url.lastPathComponent) }

    func asShotNeutral(for url: URL) async -> WhiteBalanceSample? {
        let delay = lock.withLock { asShotDelayMilliseconds }
        if delay > 0 {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        return asShotStub
    }
}

/// `SubjectMaskGenerating` のフェイク。Vision を呼ばずに用意した PNG を返す。
final class DevelopViewModelSpyMaskGenerator: SubjectMaskGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var lastKindValue: AIMaskKind?
    private var lastClickPointValue: CGPoint?
    private var delayMilliseconds = 0
    private var resultStub: SubjectMaskResult?

    var callCount: Int { lock.withLock { calls } }
    var lastKind: AIMaskKind? { lock.withLock { lastKindValue } }
    var lastClickPoint: CGPoint? { lock.withLock { lastClickPointValue } }
    var delay: Int {
        get { lock.withLock { delayMilliseconds } }
        set { lock.withLock { delayMilliseconds = newValue } }
    }
    var stub: SubjectMaskResult? {
        get { lock.withLock { resultStub } }
        set { lock.withLock { resultStub = newValue } }
    }

    func generateMask(
        for image: CGImage,
        kind: AIMaskKind,
        clickPoint: CGPoint?,
        targetLongEdge: Int
    ) async -> SubjectMaskResult? {
        let waitFor = lock.withLock {
            calls += 1
            lastKindValue = kind
            lastClickPointValue = clickPoint
            return delayMilliseconds
        }
        if waitFor > 0 { try? await Task.sleep(for: .milliseconds(waitFor)) }
        return lock.withLock { resultStub }
    }
}

enum MaskRasterTestError: Error { case notAISource }

// MARK: - ヘルパー

extension DevelopViewModelTesting {

    typealias SpyEngine = DevelopViewModelSpyEngine
    typealias SpyMaskGenerator = DevelopViewModelSpyMaskGenerator

    func makeStubImage() -> CGImage? {
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

    func makeAutomaticWhiteBalanceImage() throws -> CGImage {
        let width = 16, height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 150
            pixels[index + 1] = 160
            pixels[index + 2] = 170
            pixels[index + 3] = 255
        }
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    func makeContentViewModel() throws -> (ContentViewModel, ModelContext, Photo) {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, MaskRaster.self,
            DevelopPreset.self, FolderHistory.self, IntegrationAppSetting.self,
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

    func makeViewModel(
        engine: SpyEngine,
        maskGenerator: SpyMaskGenerator = SpyMaskGenerator(),
        content: ContentViewModel? = nil,
        dragWatchdogTimeout: Duration = .seconds(2)
    ) -> DevelopViewModel {
        DevelopViewModel(
            engine: engine,
            maskGenerator: maskGenerator,
            content: content,
            renderDebounce: .milliseconds(5),
            persistDebounce: .milliseconds(10),
            dragWatchdogTimeout: dragWatchdogTimeout
        )
    }

    func settle(_ milliseconds: UInt64 = 60) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    func makeRAWContentViewModel(
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
            settings.parametersData = try DevelopSettings.encode(params)
            context.insert(settings)
            try context.save()
        }

        let content = ContentViewModel()
        content.modelContext = context
        content.selectedPhoto = photo
        content.loadDevelopSettings(for: photo)
        return (content, context, photo)
    }

    /// プレビューが出ている（= `canEditMasks`）状態の ViewModel を用意する。
    func makeViewModelWithPreview(engine: SpyEngine) async -> DevelopViewModel {
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/mask.jpg")), displaySize: CGSize(width: 800, height: 600))
        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()
        return vm
    }

    /// ベース空間の正規化座標を作るだけの短縮形。
    func pt(_ x: Double, _ y: Double) -> NormalizedPoint {
        NormalizedPoint(x: x, y: y)
    }

    /// ストローク 1 本を引き、確定させる。
    func drawStroke(
        _ vm: DevelopViewModel,
        layerID: UUID,
        points: [NormalizedPoint]
    ) {
        guard let first = points.first else { return }
        vm.beginBrushStroke(at: first, layerID: layerID)
        for point in points.dropFirst() { vm.continueBrushStroke(at: point) }
        vm.endBrushStroke()
    }

    func makeMaskLayer() -> MaskLayer {
        MaskLayer(
            id: UUID(),
            name: "mask",
            source: .linearGradient(LinearGradientMask(
                start: NormalizedPoint(x: 0.2, y: 0.5),
                end: NormalizedPoint(x: 0.8, y: 0.5)
            )),
            adjustments: LocalAdjustments()
        )
    }

    /// グレースケール PNG を 1 枚作る。`MaskRaster.pngData` の中身として使う。
    func makeMaskPNGData(longEdge: Int = 8) throws -> Data {
        let pixels = [UInt8](repeating: 200, count: longEdge * longEdge)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.linearGray))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: longEdge, height: longEdge, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: longEdge, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// プレビュー済み・`ContentViewModel` 付きの ViewModel を作る。AI マスクは
    /// `MaskRaster` を `DevelopSettings` へ挿すため、SwiftData 側が要る。
    func makeMaskViewModelWithContent(
        engine: SpyEngine,
        maskGenerator: SpyMaskGenerator
    ) async throws -> (DevelopViewModel, ContentViewModel, Photo) {
        engine.stub = makeStubImage()
        let (content, _, photo) = try makeContentViewModel()
        let vm = makeViewModel(engine: engine, maskGenerator: maskGenerator, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()
        return (vm, content, photo)
    }

    func aiRasterID(of layer: MaskLayer) throws -> UUID {
        guard case .ai(let reference) = layer.source else {
            Issue.record("AI ソースではない")
            throw MaskRasterTestError.notAISource
        }
        return reference.rasterID
    }
}
