import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

@MainActor
struct DevelopViewModelTests: DevelopViewModelTesting {

    // MARK: - テスト

    @Test func defaultIsClippingWarningsOff() {
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.developClippingWarnings)

        let vm = DevelopViewModel(content: nil)

        #expect(vm.showsClippingWarnings == false)

        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.developClippingWarnings)
    }

    @Test func clippingWarningsChoicePersists() {
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.developClippingWarnings)
        let vm = DevelopViewModel(content: nil)
        vm.showsClippingWarnings = true

        #expect(UserDefaults.standard.object(forKey: AppSettingsKeys.developClippingWarnings) as? Bool == true)

        let restored = DevelopViewModel(content: nil)
        #expect(restored.showsClippingWarnings == true)

        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.developClippingWarnings)
    }

    @Test func neutralLoadRendersHistogramOnly() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))

        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(engine.previewCallCount == 1)
        #expect(engine.lastParameters == .neutral)
        #expect(vm.previewImage == nil)
        #expect(vm.histogram != nil)
    }

    @Test func loadPopulatesAsShotWhiteBalance() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.asShotStub = WhiteBalanceSample(temperatureKelvin: 5_200, tint: 4, isEstimated: true)
        let vm = makeViewModel(engine: engine)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(vm.asShotWhiteBalance?.temperatureKelvin == 5_200)
        #expect(vm.asShotWhiteBalanceIsEstimated)
        #expect(vm.isAsShotWhiteBalanceLoaded)
    }

    @Test func selectingCustomWhiteBalanceSeedsFromAsShot() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.asShotStub = WhiteBalanceSample(temperatureKelvin: 5_200, tint: 4, isEstimated: false)
        let vm = makeViewModel(engine: engine)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()
        vm.selectWhiteBalanceMode(.custom)

        #expect(vm.parameters.whiteBalance.temperatureKelvin == 5_200)
        #expect(vm.parameters.whiteBalance.temperatureKelvin != 6_500)
    }

    @Test func selectingCustomWithoutAsShotFallsBackTo6500() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()
        vm.selectWhiteBalanceMode(.custom)

        #expect(vm.parameters.whiteBalance.temperatureKelvin == 6_500)
    }

    @Test func setWhiteBalanceTemperatureFromAsShotModeTransitionsToCustom() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.asShotStub = WhiteBalanceSample(temperatureKelvin: 5_200, tint: 4, isEstimated: false)
        let vm = makeViewModel(engine: engine)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()
        vm.setWhiteBalanceTemperature(6_000)

        #expect(vm.parameters.whiteBalance.mode == .custom)
        #expect(vm.parameters.whiteBalance.temperatureKelvin == 6_000)
    }

    @Test func toneMaskedColorGradingFlagReachesEngine() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        var parameters = vm.parameters
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()

        #expect(engine.lastUsesToneMaskedColorGrading)
    }

    @Test func schemaBumpResyncsToneMaskedFlag() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, photo) = try makeContentViewModel()
        let settings = DevelopSettings(photoID: photo.id)
        settings.schemaVersion = 4
        var parameters = DevelopParameters.neutral
        parameters.colorBalance.master.saturation = 10
        settings.parameters = parameters
        context.insert(settings)
        try context.save()
        content.currentDevelopSettings = settings

        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        var updated = vm.parameters
        updated.exposure = 1
        vm.parameters = updated
        await settle(120)

        #expect(settings.schemaVersion == 6)
        #expect(engine.lastUsesToneMaskedColorGrading)
    }

    @Test func asShotWhiteBalanceReachesEngineWhenToneMasked() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let asShot = WhiteBalanceSample(temperatureKelvin: 5_200, tint: 4, isEstimated: true)
        engine.asShotStub = asShot
        let vm = makeViewModel(engine: engine)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()
        vm.selectWhiteBalanceMode(.custom)
        await settle()

        #expect(engine.lastAsShotWhiteBalance == asShot)
    }

    @Test func automaticWhiteBalanceWaitsForAsShotBaseline() async throws {
        let engine = SpyEngine()
        let source = try makeAutomaticWhiteBalanceImage()
        engine.stub = source
        engine.asShotStub = WhiteBalanceSample(temperatureKelvin: 5_200, tint: 4, isEstimated: true)
        engine.asShotDelay = 40
        let vm = makeViewModel(engine: engine)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        vm.applyAutomaticWhiteBalance()
        await settle(140)

        let automatic = try #require(WhiteBalanceResolver.automaticSettings(from: source))
        #expect(vm.parameters.whiteBalance.mode == .auto)
        #expect(vm.parameters.whiteBalance.temperatureKelvin == 5_200 + (automatic.temperatureKelvin - 6_500))
        #expect(vm.parameters.whiteBalance.tint == 4 + automatic.tint)
    }

    @Test func automaticWhiteBalanceFailureRestoresPreviousSettings() async throws {
        let engine = SpyEngine()
        // 4x4 の小画像は有効画素が 64 未満で WhiteBalanceResolver.automaticSettings が nil を返す（推定不能）。
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(
            photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")),
            displaySize: CGSize(width: 800, height: 600)
        )
        await settle()

        var custom = WhiteBalanceSettings(mode: .custom, temperatureKelvin: 4_200, tint: -8)
        custom.normalize()
        vm.parameters.whiteBalance = custom

        vm.applyAutomaticWhiteBalance()
        await settle()

        #expect(vm.parameters.whiteBalance == custom)
        #expect(vm.whiteBalanceStatusMessage != nil)
    }

    @Test func automaticWhiteBalanceDoesNotApplyAfterPhotoSwitch() async throws {
        let engine = SpyEngine()
        engine.stub = try makeAutomaticWhiteBalanceImage()
        engine.previewDelay = 40
        let vm = makeViewModel(engine: engine)
        let first = Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        let second = Photo(fileURL: URL(fileURLWithPath: "/tmp/b.jpg"))

        vm.load(photo: first, displaySize: CGSize(width: 800, height: 600))
        vm.applyAutomaticWhiteBalance()
        vm.load(photo: second, displaySize: CGSize(width: 800, height: 600))
        await settle(100)

        #expect(vm.parameters.whiteBalance.mode == .asShot)
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
        await settle()

        #expect(vm.parameters == .neutral)
        #expect(vm.previewImage == nil)
        #expect(vm.histogram != nil)
        #expect(vm.canReset == false)
    }

    @Test func resetSectionRevertsSectionAndSchedulesRender() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        vm.parameters.exposure = 1
        await settle()
        let renderCountBeforeReset = engine.previewCallCount

        vm.resetSection(.basic)
        await settle()

        #expect(vm.parameters.exposure == 0)
        #expect(engine.previewCallCount > renderCountBeforeReset)
        #expect(engine.lastParameters == .neutral)
    }

    @Test func resetSectionDoesNothingWhenSectionIsUnmodified() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        vm.parameters.vibrance = 20
        await settle()
        let parametersBeforeReset = vm.parameters
        let renderCountBeforeReset = engine.previewCallCount

        vm.resetSection(.basic)
        await settle()

        #expect(vm.parameters == parametersBeforeReset)
        #expect(engine.previewCallCount == renderCountBeforeReset)
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

    @Test func neutralParametersAndNoGeometryRendersHistogramOnly() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)

        // 全体矩形は実質トリミングなし。回転も無し → ヒストグラムだけをレンダーする。
        vm.load(
            photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")),
            displaySize: CGSize(width: 800, height: 600),
            rotation: 0,
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        await settle()

        #expect(engine.previewCallCount == 1)
        #expect(engine.lastParameters == .neutral)
        #expect(vm.previewImage == nil)
        #expect(vm.histogram != nil)
    }

    // MARK: - RAW 露出・WB の CIRAWFilter 委譲

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

    @Test func photoWithoutSettingsUsesManualLensCorrection() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.lensDistortion = 20
        vm.parameters = parameters
        await settle()

        #expect(engine.lastUsesManualLensCorrection)
    }

    @Test func nonRAWVersion3SettingsCanEditManualLensCorrection() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, photo) = try makeContentViewModel()
        let settings = DevelopSettings(photoID: photo.id)
        context.insert(settings)
        try context.save()
        content.loadDevelopSettings(for: photo)

        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(vm.canEditManualLensCorrection)
    }

    @Test func changingLensDistortionRendersPreview() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.lensDistortion = 20
        vm.parameters = parameters
        await settle()

        #expect(engine.previewCallCount == 1)
        #expect(engine.lastParameters?.lensDistortion == 20)
    }

    @Test func version2SettingsCanEditManualLensCorrection() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, _, photo) = try makeRAWContentViewModel(schemaVersion: 2)
        let vm = makeViewModel(engine: engine, content: content)

        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(vm.canEditManualLensCorrection)
    }

    @Test func resetVersion2SettingsEnablesManualLensCorrectionForNewEdits() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.rawFileNames = ["shot.nef"]
        let (content, _, photo) = try makeRAWContentViewModel(schemaVersion: 2)
        let vm = makeViewModel(engine: engine, content: content)

        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()
        #expect(vm.canEditManualLensCorrection)

        vm.reset()
        #expect(vm.canEditManualLensCorrection)

        var parameters = DevelopParameters.neutral
        parameters.lensDistortion = 20
        vm.parameters = parameters
        await settle(220)

        #expect(engine.lastUsesManualLensCorrection)
    }

    @Test func rawProfileLensCorrectionDisablesManualLensCorrection() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.rawFileNames = ["shot.nef"]
        let (content, _, photo) = try makeRAWContentViewModel(schemaVersion: 3)
        let vm = makeViewModel(engine: engine, content: content)

        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle(220)

        var params = vm.parameters
        params.lensDistortion = 20
        params.lensCorrectionEnabled = true
        vm.parameters = params
        await settle(220)
        #expect(engine.lastUsesManualLensCorrection == false)

        params.lensCorrectionEnabled = false
        vm.parameters = params
        await settle(220)
        #expect(engine.lastUsesManualLensCorrection)
    }

    @Test func resetVersion1RAWSettingsEnablesRAWParameterMapping() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.rawFileNames = ["shot.nef"]
        let (content, _, photo) = try makeRAWContentViewModel(schemaVersion: 1)
        let vm = makeViewModel(engine: engine, content: content)

        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()
        #expect(vm.canDelegateToRAWFilter == false)

        vm.reset()
        #expect(vm.canDelegateToRAWFilter)
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

    @Test func dragWithoutEditingChangedFalseEventuallyResumesRAWMapping() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.rawFileNames = ["shot.nef"]
        let (content, _, photo) = try makeRAWContentViewModel(schemaVersion: 2)

        let vm = makeViewModel(engine: engine, content: content, dragWatchdogTimeout: .milliseconds(30))
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        vm.setRAWParameterDragging(true)
        var params = vm.parameters
        params.exposure = 1.5
        vm.parameters = params
        await settle()
        #expect(engine.lastRAWMapping == false)

        // ドラッグ終了通知が届かないままタイムアウトを迎えると、ウォッチドッグが RAW 委譲へ戻す。
        await settle(300)
        #expect(engine.lastRAWMapping == true)
    }

    @Test func repeatedDragStartKeepsWatchdogAlive() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.rawFileNames = ["shot.nef"]
        let (content, _, photo) = try makeRAWContentViewModel(schemaVersion: 2)

        let vm = makeViewModel(engine: engine, content: content, dragWatchdogTimeout: .milliseconds(30))
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()

        // Slider が true を連続発火しても、ウォッチドッグは消えず張り直される。
        vm.setRAWParameterDragging(true)
        vm.setRAWParameterDragging(true)
        var params = vm.parameters
        params.exposure = 1.5
        vm.parameters = params
        await settle()
        #expect(engine.lastRAWMapping == false)

        await settle(300)
        #expect(engine.lastRAWMapping == true)
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

    @Test func switchingToUneditedPhotoKeepsHistogram() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, editedPhoto) = try makeContentViewModel()
        let uneditedPhoto = Photo(fileURL: URL(fileURLWithPath: "/tmp/unedited.jpg"))
        let settings = DevelopSettings(photoID: editedPhoto.id)
        var parameters = DevelopParameters.neutral
        parameters.exposure = 1.0
        settings.parameters = parameters
        context.insert(settings)
        context.insert(uneditedPhoto)
        try context.save()
        content.currentDevelopSettings = settings

        let vm = makeViewModel(engine: engine, content: content)

        vm.load(photo: editedPhoto, displaySize: CGSize(width: 800, height: 600))
        await settle()
        #expect(vm.histogram != nil)

        content.currentDevelopSettings = nil
        vm.load(photo: uneditedPhoto, displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(vm.histogram != nil)
        #expect(vm.previewImage == nil)
    }
}
