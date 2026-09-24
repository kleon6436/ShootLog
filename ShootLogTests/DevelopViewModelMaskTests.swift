import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

@MainActor
struct DevelopViewModelMaskTests: DevelopViewModelTesting {

    // MARK: - マスク（ローカル調整）

    @Test func maskEditModeCannotBeEnabledWithoutPreview() {
        let engine = SpyEngine()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        vm.maskEditMode = true

        #expect(vm.maskEditMode == false)
        #expect(vm.canEditMasks == false)
    }

    @Test func maskEditModeIsExclusiveWithBeforeAndSplitCompare() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        #expect(vm.canEditMasks)

        vm.maskEditMode = true
        #expect(vm.maskEditMode)

        vm.isShowingBefore = true
        #expect(vm.maskEditMode == false)

        vm.maskEditMode = true
        #expect(vm.isShowingBefore == false)

        vm.isComparingSplit = true
        #expect(vm.maskEditMode == false)

        vm.maskEditMode = true
        #expect(vm.isComparingSplit == false)
    }

    @Test func addLinearGradientMaskAppendsLayer() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)

        let id = try #require(vm.addLinearGradientMask())

        #expect(vm.maskLayers.count == 1)
        #expect(vm.parameters.masks.first?.id == id)
        #expect(vm.selectedMaskLayerID == id)
        if case .linearGradient = vm.parameters.masks[0].source {} else {
            Issue.record("線形グラデーション以外の生成子が入っている")
        }
    }

    @Test func addLinearGradientMaskIsNoOpWithoutPreview() {
        let engine = SpyEngine()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        #expect(vm.addLinearGradientMask() == nil)
        #expect(vm.maskLayers.isEmpty)
    }

    @Test func addRadialGradientMaskAppendsLayer() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)

        let id = try #require(vm.addRadialGradientMask())

        #expect(vm.maskLayers.count == 1)
        #expect(vm.parameters.masks.first?.id == id)
        #expect(vm.selectedMaskLayerID == id)
        if case .radialGradient(let mask) = vm.parameters.masks[0].source {
            #expect(mask.radius > 0)
            #expect(mask.aspectRatio == 1)
        } else {
            Issue.record("放射状グラデーション以外の生成子が入っている")
        }
    }

    @Test func addRadialGradientMaskIsNoOpWithoutPreview() {
        let engine = SpyEngine()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        #expect(vm.addRadialGradientMask() == nil)
        #expect(vm.maskLayers.isEmpty)
    }

    @Test func addLuminanceRangeMaskAppendsLayer() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)

        let id = try #require(vm.addLuminanceRangeMask())

        #expect(vm.maskLayers.count == 1)
        #expect(vm.parameters.masks.first?.id == id)
        #expect(vm.selectedMaskLayerID == id)
        if case .luminanceRange(let mask) = vm.parameters.masks[0].source {
            #expect(mask.lowerBound < mask.upperBound)
            #expect(mask.upperBound <= 1)
        } else {
            Issue.record("輝度レンジ以外の生成子が入っている")
        }
    }

    @Test func addLuminanceRangeMaskIsNoOpWithoutPreview() {
        let engine = SpyEngine()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        #expect(vm.addLuminanceRangeMask() == nil)
        #expect(vm.maskLayers.isEmpty)
    }

    @Test func removeMaskDropsLayerAndSelection() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())
        vm.addLinearGradientMask()

        vm.removeMask(id: id)

        #expect(vm.maskLayers.count == 1)
        #expect(vm.maskLayers.contains { $0.id == id } == false)
        #expect(vm.selectedMaskLayerID != id)
    }

    @Test func removeMaskWhileNeutralKeepsPreviewEditable() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        vm.maskEditMode = true

        // マスク以外の調整を無くし、マスクを消すと完全な無調整に戻る状態を作る。
        var params = vm.parameters
        params.exposure = 0
        vm.parameters = params
        await settle()

        let id = try #require(vm.addLinearGradientMask())
        await settle()

        vm.removeMask(id: id)
        await settle()

        #expect(vm.parameters.isNeutral)
        #expect(vm.maskEditMode)
        #expect(vm.previewImage != nil)
        #expect(vm.canEditMasks)
        #expect(vm.addLinearGradientMask() != nil)
    }

    /// 実機報告の再現条件そのもの: `maskEditMode`（オーバーレイ表示トグル）を一切オンにせず、
    /// 無調整の写真でマスクセクションを開いて追加・削除するだけのフロー。
    /// `maskEditMode` に依存する保護だけでは、このフローでは効かない。
    @Test func removeMaskWithoutMaskEditModeKeepsPreviewEditable() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/mask2.jpg")), displaySize: CGSize(width: 800, height: 600))

        // マスクセクションを開いたタイミングの動作を模倣。
        vm.prepareMaskEditingPreviewIfNeeded()
        await settle()
        #expect(vm.previewImage != nil)
        #expect(vm.canEditMasks)

        let id = try #require(vm.addLinearGradientMask())
        await settle()

        vm.removeMask(id: id)
        await settle()

        #expect(vm.parameters.isNeutral)
        #expect(vm.maskEditMode == false)
        #expect(vm.previewImage != nil)
        #expect(vm.canEditMasks)
        #expect(vm.addLinearGradientMask() != nil)
    }

    @Test func updateMaskWritesThroughToParameters() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())

        vm.updateMask(id: id) { layer in
            layer.isEnabled = false
            layer.density = 42
        }

        let layer = try #require(vm.parameters.masks.first { $0.id == id })
        #expect(layer.isEnabled == false)
        #expect(layer.density == 42)
    }

    @Test func maskChangeSchedulesPreviewRender() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let callsBeforeMask = engine.previewCallCount

        vm.addLinearGradientMask()
        await settle()

        #expect(engine.previewCallCount > callsBeforeMask)
        #expect(engine.lastParameters?.masks.count == 1)
    }

    @Test func maskOverlayRendersWhileEditingWithEnabledMask() async throws {
        let engine = SpyEngine()
        engine.maskOverlayStub = makeStubImage()
        let vm = await makeViewModelWithPreview(engine: engine)

        vm.maskEditMode = true
        vm.addLinearGradientMask()
        await settle(200)

        #expect(engine.maskOverlayCallCount > 0)
        #expect(engine.lastMaskOverlayParameters?.masks.count == 1)
        #expect(vm.maskOverlayImage != nil)
    }

    @Test func leavingMaskEditModeClearsOverlay() async throws {
        let engine = SpyEngine()
        engine.maskOverlayStub = makeStubImage()
        let vm = await makeViewModelWithPreview(engine: engine)
        vm.maskEditMode = true
        vm.addLinearGradientMask()
        await settle(200)
        #expect(vm.maskOverlayImage != nil)

        vm.maskEditMode = false
        let callsAfterLeaving = engine.maskOverlayCallCount
        await settle(200)

        #expect(vm.maskOverlayImage == nil)
        #expect(engine.maskOverlayCallCount == callsAfterLeaving)
    }

    @Test func moveMasksReordersLayers() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let first = try #require(vm.addLinearGradientMask())
        let second = try #require(vm.addLinearGradientMask())
        let third = try #require(vm.addLinearGradientMask())

        vm.moveMasks(from: IndexSet(integer: 0), to: 3)

        #expect(vm.maskLayers.map(\.id) == [second, third, first])
    }

    @Test func moveMasksIsNoOpWithoutPreview() {
        let engine = SpyEngine()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        var parameters = DevelopParameters.neutral
        parameters.masks = [makeMaskLayer(), makeMaskLayer()]
        vm.parameters = parameters
        let before = vm.maskLayers.map(\.id)

        vm.moveMasks(from: IndexSet(integer: 0), to: 2)

        #expect(vm.maskLayers.map(\.id) == before)
    }

    @Test func resetRequiresConfirmationOnlyWithMaskLayers() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        #expect(vm.resetRequiresConfirmation == false)

        let id = try #require(vm.addLinearGradientMask())
        #expect(vm.resetRequiresConfirmation)

        vm.removeMask(id: id)
        #expect(vm.resetRequiresConfirmation == false)
    }
}
