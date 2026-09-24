import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

@MainActor
struct DevelopViewModelBrushTests: DevelopViewModelTesting {

    // MARK: - ブラシ

    @Test func brushStrokeLifecycleAppendsSingleStroke() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())

        vm.beginBrushStroke(at: pt(0.1, 0.1), layerID: id)
        vm.continueBrushStroke(at: pt(0.3, 0.1))
        vm.continueBrushStroke(at: pt(0.5, 0.1))
        vm.endBrushStroke()

        let edits = try #require(vm.maskLayers.first { $0.id == id }?.brushEdits)
        #expect(edits.count == 1)
        #expect(edits[0].points.count == 3)
        #expect(edits[0].radius == vm.brushRadius)
        #expect(edits[0].isEraser == false)
    }

    @Test func brushStrokeDropsPointsTooCloseTogether() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())

        vm.beginBrushStroke(at: pt(0.1, 0.1), layerID: id)
        // しきい値（半径 0.03 では 0.002）より明らかに近い点。
        vm.continueBrushStroke(at: pt(0.1001, 0.1))
        vm.continueBrushStroke(at: pt(0.1002, 0.1))
        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.isEmpty == true)
        // 十分離れた点は採用される。
        vm.continueBrushStroke(at: pt(0.2, 0.1))
        vm.endBrushStroke()

        let edits = try #require(vm.maskLayers.first { $0.id == id }?.brushEdits)
        #expect(edits.count == 1)
        #expect(edits[0].points.count == 2)
    }

    @Test func brushStrokeDecimationStaysWithinShapeTolerance() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())

        // 斜めの直線を細かい点群でなぞる（マウスの高頻度サンプリング相当）。
        let start = pt(0.1, 0.2)
        let end = pt(0.9, 0.7)
        let sampleCount = 2000
        let samples = (0...sampleCount).map { step -> NormalizedPoint in
            let t = Double(step) / Double(sampleCount)
            return pt(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t)
        }
        drawStroke(vm, layerID: id, points: samples)

        let stroke = try #require(vm.maskLayers.first { $0.id == id }?.brushEdits.first)
        #expect(stroke.points.count < samples.count)
        // 元の軌跡（直線）から、間引き後の各点までの距離が受け入れ基準内であること。
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        let maxDeviation = stroke.points.map { point in
            abs(dy * (point.x - start.x) - dx * (point.y - start.y)) / length
        }.max() ?? 0
        #expect(maxDeviation <= 0.002)
        // 逆向きも見る: 元の点群のどれもが、間引き後の折れ線から 0.2% 以上離れていないこと。
        let maxSampleGap = samples.map { sample in
            stroke.points.map { kept in
                let ddx = sample.x - kept.x
                let ddy = sample.y - kept.y
                return (ddx * ddx + ddy * ddy).squareRoot()
            }.min() ?? .infinity
        }.max() ?? 0
        #expect(maxSampleGap <= 0.002)
    }

    @Test func brushStrokeRecordsEraserMode() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())
        vm.isBrushEraserMode = true

        drawStroke(vm, layerID: id, points: [pt(0.1, 0.1), pt(0.4, 0.4)])

        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.first?.isEraser == true)
    }

    @Test func brushStrokeLimitBlocksFurtherStrokes() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())

        let filler = BrushStroke(
            points: [BrushPoint(x: 0.5, y: 0.5)], radius: 0.03, hardness: 50, opacity: 100, isEraser: false
        )
        vm.updateMask(id: id) { $0.brushEdits = Array(repeating: filler, count: 500) }

        drawStroke(vm, layerID: id, points: [pt(0.1, 0.1), pt(0.4, 0.4)])

        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.count == 500)
        #expect(vm.brushStrokeLimitReachedMessage != nil)
        #expect(vm.canUndoBrushStroke == false)
    }

    @Test func undoLastBrushStrokeRestoresPreviousEdits() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())

        drawStroke(vm, layerID: id, points: [pt(0.1, 0.1), pt(0.4, 0.4)])
        #expect(vm.canUndoBrushStroke)

        vm.undoLastBrushStroke()

        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.isEmpty == true)
        #expect(vm.canUndoBrushStroke == false)
    }

    @Test func undoLastBrushStrokeUnwindsInOrder() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())

        drawStroke(vm, layerID: id, points: [pt(0.1, 0.1), pt(0.4, 0.4)])
        drawStroke(vm, layerID: id, points: [pt(0.2, 0.2), pt(0.6, 0.6)])
        drawStroke(vm, layerID: id, points: [pt(0.3, 0.3), pt(0.8, 0.8)])
        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.count == 3)

        vm.undoLastBrushStroke()
        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.count == 2)
        vm.undoLastBrushStroke()
        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.count == 1)
        vm.undoLastBrushStroke()
        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.isEmpty == true)
        #expect(vm.canUndoBrushStroke == false)

        vm.undoLastBrushStroke()
        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.isEmpty == true)
    }

    @Test func loadClearsBrushUndoStackAndActiveStroke() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())
        drawStroke(vm, layerID: id, points: [pt(0.1, 0.1), pt(0.4, 0.4)])
        vm.beginBrushStroke(at: pt(0.2, 0.2), layerID: id)
        #expect(vm.canUndoBrushStroke)

        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/other.jpg")), displaySize: CGSize(width: 800, height: 600))

        #expect(vm.canUndoBrushStroke == false)
        // 進行中ストロークも破棄されているので、確定しても何も起きない。
        vm.endBrushStroke()
        #expect(vm.maskLayers.isEmpty)
    }

    @Test func beginBrushStrokeIsNoOpWithoutPreview() {
        let engine = SpyEngine()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        #expect(vm.canEditMasks == false)

        vm.beginBrushStroke(at: pt(0.1, 0.1), layerID: UUID())
        vm.continueBrushStroke(at: pt(0.4, 0.4))
        vm.endBrushStroke()

        #expect(vm.maskLayers.isEmpty)
        #expect(vm.canUndoBrushStroke == false)
    }

    /// 構造不変条件: ドラッグ中（`continueBrushStroke`）は `parameters` を書き換えない。
    /// UI 側がこの間に再ラスタライズを走らせないための前提なので、明示的に固定する。
    @Test func continueBrushStrokeLeavesParametersUntouched() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let id = try #require(vm.addLinearGradientMask())
        let snapshot = vm.parameters

        vm.beginBrushStroke(at: pt(0.1, 0.1), layerID: id)
        vm.continueBrushStroke(at: pt(0.3, 0.1))
        vm.continueBrushStroke(at: pt(0.5, 0.1))
        vm.continueBrushStroke(at: pt(0.7, 0.1))
        #expect(vm.parameters == snapshot)

        vm.endBrushStroke()
        #expect(vm.parameters != snapshot)
        #expect(vm.maskLayers.first { $0.id == id }?.brushEdits.count == 1)
    }

    @Test func addBrushMaskSelectsLayerAndEntersPaintMode() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)

        let id = try #require(vm.addBrushMask())

        let layer = try #require(vm.maskLayers.first { $0.id == id })
        #expect(layer.source == MaskSource.none)
        #expect(layer.brushEdits.isEmpty)
        #expect(vm.selectedMaskLayerID == id)
        #expect(vm.isBrushPaintMode)
    }

    @Test func addBrushMaskIsNoOpWithoutPreview() {
        let engine = SpyEngine()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        #expect(vm.addBrushMask() == nil)
        #expect(vm.maskLayers.isEmpty)
        #expect(vm.isBrushPaintMode == false)
    }

    /// 別レイヤーを選び直したら、前のレイヤーへ描き続けないようペイントモードを抜ける。
    @Test func selectingAnotherLayerLeavesPaintMode() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        let gradientID = try #require(vm.addLinearGradientMask())
        vm.addBrushMask()
        #expect(vm.isBrushPaintMode)

        vm.selectedMaskLayerID = gradientID

        #expect(vm.isBrushPaintMode == false)
    }

    @Test func leavingMaskEditModeLeavesPaintMode() async throws {
        let engine = SpyEngine()
        let vm = await makeViewModelWithPreview(engine: engine)
        vm.addBrushMask()
        vm.maskEditMode = true
        #expect(vm.isBrushPaintMode)

        vm.maskEditMode = false

        #expect(vm.isBrushPaintMode == false)
    }
}
