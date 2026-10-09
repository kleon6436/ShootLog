import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

@MainActor
struct DevelopViewModelAIMaskTests: DevelopViewModelTesting {

    // MARK: - AI マスク

    @Test func addAIMaskAppendsLayerAndSelectsIt() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0, 2]
        )
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)

        await vm.addAIMask(kind: .foregroundSubject)

        #expect(vm.maskLayers.count == 1)
        let layer = try #require(vm.maskLayers.first)
        #expect(vm.selectedMaskLayerID == layer.id)
        guard case .ai(let reference) = layer.source else {
            Issue.record("AI ソースではない: \(layer.source)")
            return
        }
        #expect(reference.kind == .foregroundSubject)
        #expect(reference.instanceIndices == [0, 2])
        #expect(reference.bakedLongEdge == 8)
        #expect(reference.visionRevision == DevelopViewModel.currentVisionRevision)
        #expect(generator.lastKind == .foregroundSubject)
        #expect(generator.lastClickPoint == nil)
    }

    @Test func addAIMaskFlipsClickPointToVisionCoordinates() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)

        await vm.addAIMask(kind: .person, clickPoint: NormalizedPoint(x: 0.25, y: 0.75))

        let point = try #require(generator.lastClickPoint)
        #expect(point.x == 0.25)
        #expect(point.y == 0.25)
    }

    @Test func addAIMaskReportsFailureWhenNothingDetected() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = nil
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)

        await vm.addAIMask(kind: .foregroundSubject)

        #expect(vm.maskLayers.isEmpty)
        #expect(vm.aiMaskGenerationFailureMessage != nil)
        #expect(vm.isGeneratingAIMask == false)
    }

    @Test func addAIMaskIsNoOpWithoutPreview() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (content, _, photo) = try makeContentViewModel()
        let vm = makeViewModel(engine: engine, maskGenerator: generator, content: content)
        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle()
        #expect(vm.canEditMasks == false)

        await vm.addAIMask(kind: .foregroundSubject)

        #expect(vm.maskLayers.isEmpty)
        #expect(generator.callCount == 0)
    }

    @Test func isGeneratingAIMaskIsTrueWhileRunning() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.delay = 150
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)

        let task = Task { await vm.addAIMask(kind: .foregroundSubject) }
        await settle(60)
        #expect(vm.isGeneratingAIMask)
        // 生成中でもプレビュー再描画のような他の MainActor 処理は止まらない。
        vm.parameters.contrast = 10
        #expect(vm.parameters.contrast == 10)

        await task.value
        #expect(vm.isGeneratingAIMask == false)
        #expect(vm.maskLayers.count == 1)
    }

    @Test func addAIMaskInsertsRasterIntoDevelopSettings() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        let pngData = try makeMaskPNGData()
        generator.stub = SubjectMaskResult(pngData: pngData, longEdge: 8, instanceIndices: [0])
        let (vm, content, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)

        await vm.addAIMask(kind: .foregroundSubject)

        guard case .ai(let reference) = try #require(vm.maskLayers.first).source else {
            Issue.record("AI ソースではない")
            return
        }
        let settings = try #require(content.currentDevelopSettings)
        let raster = try #require(settings.maskRasters.first(where: { $0.id == reference.rasterID }))
        #expect(raster.pngData == pngData)
        #expect(raster.longEdge == 8)
    }

    @Test func aiMaskRasterReachesRenderPreview() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)

        await vm.addAIMask(kind: .foregroundSubject)
        await settle(200)

        guard case .ai(let reference) = try #require(vm.maskLayers.first).source else {
            Issue.record("AI ソースではない")
            return
        }
        #expect(engine.lastMaskRasters[reference.rasterID] != nil)
    }

    @Test func decodedMaskRasterIsReusedAcrossRenders() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        await settle(200)
        guard case .ai(let reference) = try #require(vm.maskLayers.first).source else {
            Issue.record("AI ソースではない")
            return
        }
        let first = try #require(engine.lastMaskRasters[reference.rasterID])

        vm.parameters.contrast = 20
        await settle(200)

        // 同一インスタンスなら PNG を展開し直していない。
        #expect(engine.lastMaskRasters[reference.rasterID] === first)
    }

    @Test func reloadingPhotoDropsDecodedMaskRasterCache() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, _, photo) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        await settle(200)
        guard case .ai(let reference) = try #require(vm.maskLayers.first).source else {
            Issue.record("AI ソースではない")
            return
        }
        let first = try #require(engine.lastMaskRasters[reference.rasterID])

        vm.load(photo: photo, displaySize: CGSize(width: 800, height: 600))
        await settle(200)

        let reloaded = try #require(engine.lastMaskRasters[reference.rasterID])
        #expect(reloaded !== first)
    }

    @Test func maskNeedsRegenerationOnlyForStaleVisionRevision() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        let fresh = try #require(vm.maskLayers.first)
        #expect(vm.maskNeedsRegeneration(fresh) == false)

        var stale = fresh
        guard case .ai(var reference) = stale.source else {
            Issue.record("AI ソースではない")
            return
        }
        reference.visionRevision = DevelopViewModel.currentVisionRevision - 1
        stale.source = .ai(reference)
        #expect(vm.maskNeedsRegeneration(stale))
        #expect(vm.maskNeedsRegeneration(makeMaskLayer()) == false)
    }

    @Test func regenerateAIMaskReplacesRasterInPlace() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .person)
        let original = try #require(vm.maskLayers.first)
        let originalRasterID = try aiRasterID(of: original)
        let above = try #require(vm.addLinearGradientMask())

        await vm.regenerateAIMask(id: original.id)

        // レイヤーの ID・重なり順は変わらず、ラスタ参照だけが新しくなる。
        #expect(vm.maskLayers.map(\.id) == [original.id, above])
        let regenerated = try #require(vm.maskLayers.first)
        #expect(try aiRasterID(of: regenerated) != originalRasterID)
        #expect(vm.selectedMaskLayerID == original.id)
        #expect(generator.lastKind == .person)
        #expect(generator.lastClickPoint == nil)
    }

    /// 再生成・クリックでの絞り込みは、ローカル調整・反転・濃度・ぼかし・名前・ブラシ編集を保つ。
    /// 旧実装は新規レイヤーの追加＋旧レイヤー削除で、これらが全部初期化され最前面へ移っていた。
    @Test func refiningAIMaskPreservesLayerSettings() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0, 1]
        )
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        let below = try #require(vm.addLinearGradientMask())
        let addedID = await vm.addAIMask(kind: .foregroundSubject)
        let id = try #require(addedID)
        let above = try #require(vm.addRadialGradientMask())
        vm.updateMask(id: id) { layer in
            layer.name = "Sky"
            layer.isInverted = true
            layer.density = 40
            layer.feather = 25
            layer.adjustments.exposure = 0.7
        }
        let before = try #require(vm.maskLayers.first(where: { $0.id == id }))

        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [1]
        )
        await vm.regenerateAIMask(id: id, clickPoint: NormalizedPoint(x: 0.25, y: 0.75))

        #expect(vm.maskLayers.map(\.id) == [below, id, above])
        let after = try #require(vm.maskLayers.first(where: { $0.id == id }))
        #expect(after.name == "Sky")
        #expect(after.isInverted)
        #expect(after.density == 40)
        #expect(after.feather == 25)
        #expect(after.adjustments == before.adjustments)
        #expect(after.brushEdits == before.brushEdits)
        guard case .ai(let reference) = after.source else {
            Issue.record("AI ソースではない: \(after.source)")
            return
        }
        #expect(reference.instanceIndices == [1])
        #expect(reference.kind == .foregroundSubject)
        #expect(try aiRasterID(of: after) != aiRasterID(of: before))
        // クリック位置は Vision 座標（y 反転）で渡る。
        #expect(generator.lastClickPoint?.y == 0.25)
    }

    @Test func regenerateAIMaskKeepsLayerWhenGenerationFails() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        let original = try #require(vm.maskLayers.first).id

        generator.stub = nil
        await vm.regenerateAIMask(id: original)

        #expect(vm.maskLayers.map(\.id) == [original])
        #expect(vm.aiMaskGenerationFailureMessage != nil)
    }

    // MARK: - MaskRaster の参照整合性

    @Test func presetAIMaskIsExcludedEvenWithIncludeMasks() async throws {
        // レビュー指摘対応: DevelopPresetは写真をまたいで使うのが本来の用途だが、AIマスクの
        // ラスタは元写真のDevelopSettingsにしか存在しないため、別写真への適用時にほぼ確実に
        // 複製元が見つからず「見た目はあるが効かないレイヤー」ができてしまっていた。
        // includeMasks: true でもAIマスクだけは常に除外するよう変更した（applyPreset参照）。
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, content, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        let originalRasterID = try aiRasterID(of: try #require(vm.maskLayers.first))

        let preset = DevelopPreset(name: "P", parameters: vm.parameters, sortIndex: 0)
        vm.applyPreset(preset, relative: true, includeMasks: true)

        // プリセット側のAIマスクはappendされない。元の1枚のみ残り、ラスタも複製されない。
        #expect(vm.maskLayers.count == 1)
        #expect(try aiRasterID(of: try #require(vm.maskLayers.first)) == originalRasterID)
        let settings = try #require(content.currentDevelopSettings)
        #expect(settings.maskRasters.map(\.id) == [originalRasterID])
    }

    @Test func saveCurrentAsPresetExcludesAIMaskEvenWithIncludeMasks() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, content, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        let context = try #require(content.modelContext)

        vm.saveCurrentAsPreset(name: "P", includeMasks: true)

        let saved = try context.fetch(FetchDescriptor<DevelopPreset>())
        #expect(saved.first?.parameters.masks.isEmpty == true)
    }

    @Test func pastedAIMaskIsExcludedByDefault() async throws {
        // プラン§3.6: AIマスクは被写体位置が写真ごとに異なるため、コピー＆ペーストの既定に
        // 含めない（線形/放射状グラデーション・輝度レンジは既定で含める）。
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        let (vm, _, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)

        var source = DevelopParameters.neutral
        source.exposure = 2
        source.masks = [MaskLayer(
            id: UUID(),
            name: "ai",
            source: .ai(AIMaskReference(
                rasterID: UUID(), kind: .person, instanceIndices: [0],
                visionRevision: DevelopViewModel.currentVisionRevision, bakedLongEdge: 8, bakedAt: .now
            )),
            adjustments: LocalAdjustments()
        )]
        // コピー元は別の ViewModel（別写真）として用意する。貼り付け先は AI マスクを持たない。
        let other = makeViewModel(engine: SpyEngine())
        other.parameters = source
        other.copyAdjustments()
        vm.parameters.exposure = 0.25

        vm.pasteAdjustments()

        #expect(vm.parameters.exposure == 2)
        #expect(vm.maskLayers.isEmpty)
    }

    /// ペーストは貼り付け先自身の AI マスクを残し、移せるレイヤーだけをクリップボード側で置き換える
    /// （マスクを含めないプリセット置き換えが現在のマスクを保持するのと揃える）。
    @Test func pasteKeepsTargetsOwnAIMasks() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, content, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        let addedID = await vm.addAIMask(kind: .foregroundSubject)
        let ownAI = try #require(addedID)
        let ownRasterID = try aiRasterID(of: try #require(vm.maskLayers.first))
        let ownLinear = try #require(vm.addLinearGradientMask())

        var source = DevelopParameters.neutral
        source.exposure = 2
        let pastedLayer = makeMaskLayer()
        source.masks = [
            MaskLayer(
                id: UUID(),
                name: "foreign-ai",
                source: .ai(AIMaskReference(
                    rasterID: UUID(), kind: .person, instanceIndices: [0],
                    visionRevision: DevelopViewModel.currentVisionRevision, bakedLongEdge: 8, bakedAt: .now
                )),
                adjustments: LocalAdjustments()
            ),
            pastedLayer,
        ]
        let other = makeViewModel(engine: SpyEngine())
        other.parameters = source
        other.copyAdjustments()

        vm.pasteAdjustments()

        #expect(vm.parameters.exposure == 2)
        #expect(vm.maskLayers.map(\.id) == [ownAI, pastedLayer.id])
        #expect(vm.maskLayers.contains { $0.id == ownLinear } == false)
        #expect(try aiRasterID(of: try #require(vm.maskLayers.first)) == ownRasterID)
        // 自前の AI ラスタを複製していない。
        let settings = try #require(content.currentDevelopSettings)
        #expect(settings.maskRasters.map(\.id) == [ownRasterID])
    }

    /// AI マスクを外して中立になるプリセット適用でもレコード（＝MaskRaster）を消さず、
    /// 1 段 Undo で戻した AI マスクがラスタを参照し続けられる。
    @Test func neutralApplyKeepsRecordSoUndoRestoresAIMaskRaster() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, content, photo) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        let rasterID = try aiRasterID(of: try #require(vm.maskLayers.first))
        await settle()
        let context = try #require(content.modelContext)

        vm.applyPreset(DevelopPreset(name: "N", parameters: .neutral, sortIndex: 0), includeMasks: true)
        #expect(vm.parameters.isNeutral)
        await settle()

        #expect(try context.fetch(FetchDescriptor<DevelopSettings>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<MaskRaster>()).map(\.id) == [rasterID])

        vm.undoLastApply()
        await settle()

        #expect(try aiRasterID(of: try #require(vm.maskLayers.first)) == rasterID)
        let settings = try #require(content.developSettings(forPhotoID: photo.id))
        #expect(settings.maskRasters.map(\.id) == [rasterID])
        #expect(settings.parameters.exposure == 1)
    }

    /// Undo のために残した中立レコードは、写真を離れた時点で通常どおり削除される。
    @Test func neutralRecordKeptForUndoIsRemovedWhenLeavingPhoto() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, content, photo) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        await settle()
        let context = try #require(content.modelContext)

        vm.applyPreset(DevelopPreset(name: "N", parameters: .neutral, sortIndex: 0), includeMasks: true)
        await settle()
        #expect(try context.fetch(FetchDescriptor<DevelopSettings>()).count == 1)

        let next = Photo(fileURL: URL(fileURLWithPath: "/tmp/develop-vm-test-next3.jpg"))
        context.insert(next)
        content.selectedPhoto = next
        content.loadDevelopSettings(for: next)
        vm.load(photo: next, displaySize: CGSize(width: 800, height: 600))
        await settle()

        let rows = try context.fetch(FetchDescriptor<DevelopSettings>())
        #expect(rows.contains { $0.photoID == photo.id } == false)
        #expect(try context.fetch(FetchDescriptor<MaskRaster>()).isEmpty)
    }

    @Test func photoSwitchCollectsOrphanedRastersOfLeavingPhotoOnly() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, content, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        let orphanedRasterID = try aiRasterID(of: try #require(vm.maskLayers.first))
        let context = try #require(content.modelContext)

        // レイヤーを消しただけでは blob から参照が外れるだけでラスタは残る。
        vm.removeMask(id: try #require(vm.maskLayers.first).id)
        await settle()
        #expect(try context.fetch(FetchDescriptor<MaskRaster>()).count == 1)

        // 別写真へ切り替える。実際の選択経路と同じく currentDevelopSettings は先に差し替わる。
        let next = Photo(fileURL: URL(fileURLWithPath: "/tmp/develop-vm-test-next.jpg"))
        context.insert(next)
        content.selectedPhoto = next
        content.loadDevelopSettings(for: next)
        vm.load(photo: next, displaySize: CGSize(width: 800, height: 600))
        await settle()

        let remaining = try context.fetch(FetchDescriptor<MaskRaster>())
        #expect(remaining.isEmpty)
        #expect(remaining.contains(where: { $0.id == orphanedRasterID }) == false)
    }

    @Test func photoSwitchKeepsReferencedRastersOfLeavingPhoto() async throws {
        let engine = SpyEngine()
        let generator = SpyMaskGenerator()
        generator.stub = SubjectMaskResult(
            pngData: try makeMaskPNGData(), longEdge: 8, instanceIndices: [0]
        )
        let (vm, content, _) = try await makeMaskViewModelWithContent(engine: engine, maskGenerator: generator)
        await vm.addAIMask(kind: .foregroundSubject)
        let keptRasterID = try aiRasterID(of: try #require(vm.maskLayers.first))
        let context = try #require(content.modelContext)

        let next = Photo(fileURL: URL(fileURLWithPath: "/tmp/develop-vm-test-next2.jpg"))
        context.insert(next)
        content.selectedPhoto = next
        content.loadDevelopSettings(for: next)
        vm.load(photo: next, displaySize: CGSize(width: 800, height: 600))
        await settle()

        #expect(try context.fetch(FetchDescriptor<MaskRaster>()).map(\.id) == [keptRasterID])
    }
}
