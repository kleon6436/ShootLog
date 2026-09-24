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
}
