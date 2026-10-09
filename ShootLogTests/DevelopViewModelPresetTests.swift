import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

@MainActor
struct DevelopViewModelPresetTests: DevelopViewModelTesting {

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

    @Test func relativePresetApplyAddsToCurrentAndIsUndoable() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var start = DevelopParameters.neutral
        start.exposure = 0.8
        start.contrast = 10
        vm.parameters = start
        await settle()

        var presetParams = DevelopParameters.neutral
        presetParams.contrast = 20
        presetParams.saturation = 15
        vm.applyPreset(DevelopPreset(name: "style", parameters: presetParams, sortIndex: 0), relative: true)

        // 露出は保たれ、コントラストは加算、彩度はプリセット分。
        #expect(vm.parameters.exposure == 0.8)
        #expect(vm.parameters.contrast == 30)
        #expect(vm.parameters.saturation == 15)
        #expect(vm.canUndo)

        vm.undoLastApply()
        #expect(vm.parameters.exposure == 0.8)
        #expect(vm.parameters.contrast == 10)
        #expect(vm.parameters.saturation == 0)
    }

    @Test func setPreviewColorSpaceReRendersWithThatSpaceOnChange() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var params = DevelopParameters.neutral
        params.exposure = 0.5
        vm.parameters = params
        await settle()
        let callsBeforeColorSpace = engine.previewCallCount

        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        vm.setPreviewColorSpace(p3)
        await settle()
        #expect(engine.previewCallCount > callsBeforeColorSpace)
        #expect(engine.lastPreviewColorSpace.map { CFEqual($0, p3) } == true)

        // 同じ色空間の再設定は再レンダーを起こさない。
        let callsAfterFirst = engine.previewCallCount
        vm.setPreviewColorSpace(p3)
        await settle()
        #expect(engine.previewCallCount == callsAfterFirst)
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

    // MARK: - プリセットとマスク

    @Test func saveCurrentAsPresetExcludesMasksByDefault() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, photo) = try makeRAWContentViewModel(schemaVersion: nil)
        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        vm.parameters.exposure = 1
        await settle()
        vm.addLinearGradientMask()

        vm.saveCurrentAsPreset(name: "no-masks")

        let saved = try context.fetch(FetchDescriptor<DevelopPreset>())
        #expect(saved.count == 1)
        #expect(saved.first?.parameters.masks.isEmpty == true)
    }

    @Test func saveCurrentAsPresetKeepsMasksWhenRequested() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, photo) = try makeRAWContentViewModel(schemaVersion: nil)
        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        vm.parameters.exposure = 1
        await settle()
        vm.addLinearGradientMask()

        vm.saveCurrentAsPreset(name: "with-masks", includeMasks: true)

        let saved = try context.fetch(FetchDescriptor<DevelopPreset>())
        #expect(saved.first?.parameters.masks.count == 1)
    }

    @Test func applyPresetKeepsCurrentMasksWhenNotIncluded() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let existing = try #require(vm.addLinearGradientMask())

        var presetParams = DevelopParameters.neutral
        presetParams.contrast = 40
        presetParams.masks = [makeMaskLayer()]
        vm.applyPreset(DevelopPreset(name: "P", parameters: presetParams, sortIndex: 0))

        #expect(vm.parameters.contrast == 40)
        #expect(vm.maskLayers.map(\.id) == [existing])
    }

    @Test func applyPresetReplacesMasksWhenIncluded() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        vm.addLinearGradientMask()

        var presetParams = DevelopParameters.neutral
        let presetMask = makeMaskLayer()
        presetParams.masks = [presetMask]
        vm.applyPreset(DevelopPreset(name: "P", parameters: presetParams, sortIndex: 0), includeMasks: true)

        #expect(vm.maskLayers.map(\.id) == [presetMask.id])
    }

    @Test func relativePresetApplyDoesNotAppendMasksWhenNotIncluded() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let existing = try #require(vm.addLinearGradientMask())

        var presetParams = DevelopParameters.neutral
        presetParams.contrast = 20
        presetParams.masks = [makeMaskLayer()]
        vm.applyPreset(DevelopPreset(name: "P", parameters: presetParams, sortIndex: 0), relative: true)

        #expect(vm.parameters.contrast == 20)
        #expect(vm.maskLayers.map(\.id) == [existing])
    }

    @Test func relativePresetApplyAppendsMasksWithReissuedIDsWhenIncluded() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let existing = try #require(vm.addLinearGradientMask())

        var presetParams = DevelopParameters.neutral
        let presetMask = makeMaskLayer()
        presetParams.masks = [presetMask]
        let preset = DevelopPreset(name: "P", parameters: presetParams, sortIndex: 0)
        vm.applyPreset(preset, relative: true, includeMasks: true)

        #expect(vm.maskLayers.count == 2)
        #expect(vm.maskLayers[0].id == existing)
        // 同じプリセットを重ねても id が衝突しないよう、追記側は再発行される。
        #expect(vm.maskLayers[1].id != presetMask.id)
        #expect(vm.maskLayers[1].source == presetMask.source)
    }

    @Test func maskOverlayIsNotRenderedWhenAllMasksDisabled() async throws {
        let engine = SpyEngine()
        engine.maskOverlayStub = makeStubImage()
        let vm = await makeViewModelWithPreview(engine: engine)
        vm.maskEditMode = true
        let id = try #require(vm.addLinearGradientMask())
        await settle(200)

        vm.updateMask(id: id) { $0.isEnabled = false }
        await settle(200)

        #expect(vm.maskOverlayImage == nil)
    }

    // MARK: - Auto ホワイトバランスの持ち込み

    /// コピー元（別写真）で推定した Auto WB の値を、別 ViewModel のクリップボード経由で用意する。
    private func copyAutoWhiteBalanceFromAnotherPhoto() {
        var source = DevelopParameters.neutral
        source.exposure = 1
        source.whiteBalance = WhiteBalanceSettings(mode: .auto, temperatureKelvin: 3_000, tint: 30)
        let other = makeViewModel(engine: SpyEngine())
        other.parameters = source
        other.copyAdjustments()
    }

    @Test func pastingAutoWhiteBalanceReestimatesForTargetPhoto() async throws {
        let engine = SpyEngine()
        let image = try makeAutomaticWhiteBalanceImage()
        engine.stub = image
        engine.asShotStub = WhiteBalanceSample(temperatureKelvin: 5_200, tint: 4, isEstimated: true)
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()
        copyAutoWhiteBalanceFromAnotherPhoto()

        vm.pasteAdjustments()
        await settle(140)

        let automatic = try #require(WhiteBalanceResolver.automaticSettings(from: image))
        #expect(vm.parameters.exposure == 1)
        #expect(vm.parameters.whiteBalance.mode == .auto)
        // コピー元の 3000K / +30 ではなく、貼り付け先の画像で推定し直した値になる。
        #expect(vm.parameters.whiteBalance.temperatureKelvin == 5_200 - (automatic.temperatureKelvin - 6_500))
        #expect(vm.parameters.whiteBalance.tint == 4 + automatic.tint)
    }

    @Test func relativePresetWithAutoWhiteBalanceReestimatesForTargetPhoto() async throws {
        let engine = SpyEngine()
        let image = try makeAutomaticWhiteBalanceImage()
        engine.stub = image
        engine.asShotStub = WhiteBalanceSample(temperatureKelvin: 5_200, tint: 4, isEstimated: true)
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()

        var presetParams = DevelopParameters.neutral
        presetParams.whiteBalance = WhiteBalanceSettings(mode: .auto, temperatureKelvin: 3_000, tint: 30)
        vm.applyPreset(DevelopPreset(name: "auto", parameters: presetParams, sortIndex: 0), relative: true)
        await settle(140)

        let automatic = try #require(WhiteBalanceResolver.automaticSettings(from: image))
        #expect(vm.parameters.whiteBalance.mode == .auto)
        #expect(vm.parameters.whiteBalance.temperatureKelvin == 5_200 - (automatic.temperatureKelvin - 6_500))
    }

    @Test func pastedAutoWhiteBalanceFallsBackToPreviousWhenEstimationFails() async throws {
        let engine = SpyEngine()
        // 4x4 の小画像は WhiteBalanceResolver.automaticSettings が nil を返す（推定不能）。
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()
        copyAutoWhiteBalanceFromAnotherPhoto()

        vm.pasteAdjustments()
        await settle(140)

        #expect(vm.parameters.exposure == 1)
        #expect(vm.parameters.whiteBalance == .neutral)
        #expect(vm.whiteBalanceStatusMessage != nil)
    }

    @Test func undoBeforeAutoWhiteBalanceEstimateCompletesIsNotOverwritten() async throws {
        let engine = SpyEngine()
        engine.stub = try makeAutomaticWhiteBalanceImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()
        copyAutoWhiteBalanceFromAnotherPhoto()
        engine.previewDelay = 40

        vm.pasteAdjustments()
        vm.undoLastApply()
        await settle(160)

        #expect(vm.parameters == .neutral)
    }

    // MARK: - Undo と schemaVersion

    /// 中立になる適用でレコードを消すと、Undo 後に現行世代で作り直され v1 RAW の解釈が変わっていた。
    @Test func undoAfterNeutralApplyKeepsLegacySchemaVersion() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        engine.rawFileNames = ["shot.nef"]
        let (content, context, photo) = try makeRAWContentViewModel(schemaVersion: 1)
        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        #expect(vm.canDelegateToRAWFilter == false)

        vm.applyPreset(DevelopPreset(name: "N", parameters: .neutral, sortIndex: 0))
        await settle()
        vm.undoLastApply()
        await settle()

        let rows = try context.fetch(FetchDescriptor<DevelopSettings>())
        #expect(rows.count == 1)
        #expect(rows.first?.schemaVersion == 1)
        #expect(rows.first?.parameters.exposure == 0.5)
        #expect(vm.canDelegateToRAWFilter == false)
    }

    /// 適用で世代が引き上がっても、Undo で適用前の世代へ戻す（旧方式カラーグレーディングの凍結を保つ）。
    @Test func undoRestoresSchemaVersionBumpedByApply() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let (content, context, photo) = try makeContentViewModel()
        let settings = DevelopSettings(photoID: photo.id)
        settings.schemaVersion = 4
        var legacy = DevelopParameters.neutral
        legacy.exposure = 0.3
        // 旧方式のカラーグレーディングが入った v4 レコード（編集しても 4 で凍結される）。
        legacy.colorBalance.shadows = ColorBalanceComponent(hue: 20, saturation: 30, lightness: 0)
        settings.parametersData = try DevelopSettings.encode(legacy)
        context.insert(settings)
        try context.save()
        content.loadDevelopSettings(for: photo)
        let vm = makeViewModel(engine: engine, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))

        // カラーグレーディングが中立のプリセットで置き換えると現行世代へ引き上がる。
        var presetParams = DevelopParameters.neutral
        presetParams.contrast = 40
        vm.applyPreset(DevelopPreset(name: "P", parameters: presetParams, sortIndex: 0))
        await settle()
        #expect(settings.schemaVersion == DevelopSettings.currentSchemaVersion)

        vm.undoLastApply()
        await settle()

        #expect(settings.schemaVersion == 4)
        #expect(settings.parameters.exposure == 0.3)
        #expect(settings.parameters.colorBalance == legacy.colorBalance)
    }
}
