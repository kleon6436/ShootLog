import Testing

@testable import ShootLog

struct SuperResolutionModelCatalogTests {

    @Test func allRegistersBothBundledModels() {
        #expect(SuperResolutionModelCatalog.all.count == 2)
        #expect(SuperResolutionModelCatalog.all.contains(SuperResolutionModelCatalog.realesrganX4))
        #expect(SuperResolutionModelCatalog.all.contains(SuperResolutionModelCatalog.realesrganX2))
    }

    @Test func descriptorResolvesBothModelIDs() {
        #expect(SuperResolutionModelCatalog.descriptor(for: "realesrgan") == SuperResolutionModelCatalog.realesrganX4)
        #expect(
            SuperResolutionModelCatalog.descriptor(for: "realesrgan_x2plus")
                == SuperResolutionModelCatalog.realesrganX2
        )
        #expect(SuperResolutionModelCatalog.descriptor(for: "does_not_exist") == nil)
    }

    // 既存4倍モデルの値は2倍モデル追加時にカタログへ移設しただけで、変更していない（回帰防止）
    @Test func quadrupleModelKeepsShippedValues() {
        let descriptor = SuperResolutionModelCatalog.realesrganX4
        #expect(descriptor.id == "realesrgan")
        #expect(descriptor.scaleFactor == 4)
        #expect(descriptor.isTrainedAlgorithmicMedia)
        #expect(descriptor.tileLayout.inputTileSize == 128)
        #expect(descriptor.tileLayout.outputTileSize == 512)
        #expect(descriptor.tileLayout.inputOverlap == 8)
    }

    // 2倍モデルの実測確定値（Tools/CoreML/README.md「2倍モデルの実測結果」）
    @Test func doubleModelUsesMeasuredTileLayout() {
        let descriptor = SuperResolutionModelCatalog.realesrganX2
        #expect(descriptor.id == "realesrgan_x2plus")
        #expect(descriptor.scaleFactor == 2)
        #expect(descriptor.isTrainedAlgorithmicMedia)
        #expect(descriptor.tileLayout.inputTileSize == 128)
        #expect(descriptor.tileLayout.outputTileSize == 256)
        #expect(descriptor.tileLayout.inputOverlap == 8)
        #expect(descriptor.tileLayout.isValid)
    }

    @Test func aiModelResolvesByScaleFactor() {
        #expect(SuperResolutionModelCatalog.aiModel(forScaleFactor: 2) == SuperResolutionModelCatalog.realesrganX2)
        #expect(SuperResolutionModelCatalog.aiModel(forScaleFactor: 4) == SuperResolutionModelCatalog.realesrganX4)
        #expect(SuperResolutionModelCatalog.aiModel(forScaleFactor: 3) == nil)
    }

    // 従来方式は補間アルゴリズムのため任意倍率で組み立てられ、AI生成物マーカーを付けない
    @Test func lanczosBuildsRequestedScaleFactor() {
        for scaleFactor in [2, 4] {
            let descriptor = SuperResolutionModelCatalog.lanczos(scaleFactor: scaleFactor)
            #expect(descriptor.id == "lanczos")
            #expect(descriptor.scaleFactor == scaleFactor)
            #expect(!descriptor.isTrainedAlgorithmicMedia)
            #expect(descriptor.tileLayout.outputTileSize == 128 * scaleFactor)
        }
    }

    @Test func makeEngineSelectsLanczosOnlyForLanczosDescriptor() {
        let lanczosEngine = SuperResolutionModelCatalog.makeEngine(
            for: SuperResolutionModelCatalog.lanczos(scaleFactor: 4)
        )
        #expect(lanczosEngine is LanczosSuperResolutionEngine)

        for descriptor in SuperResolutionModelCatalog.all {
            #expect(SuperResolutionModelCatalog.makeEngine(for: descriptor) is CoreMLSuperResolutionEngine)
        }
    }
}

@MainActor
struct UpscaleDescriptorResolutionTests {

    @Test func aiEngineResolvesModelMatchingSelectedScale() {
        let double = ContentViewModel.descriptor(for: .aiSuperResolution, scaleFactor: 2)
        #expect(double?.id == "realesrgan_x2plus")
        #expect(double?.scaleFactor == 2)

        let quadruple = ContentViewModel.descriptor(for: .aiSuperResolution, scaleFactor: 4)
        #expect(quadruple?.id == "realesrgan")
        #expect(quadruple?.scaleFactor == 4)
    }

    @Test func traditionalEngineResolvesLanczosAtSelectedScale() {
        #expect(ContentViewModel.descriptor(for: .traditional, scaleFactor: 2)?.id == "lanczos")
        #expect(ContentViewModel.descriptor(for: .traditional, scaleFactor: 2)?.scaleFactor == 2)
        #expect(ContentViewModel.descriptor(for: .traditional, scaleFactor: 4)?.scaleFactor == 4)
    }

    // 同梱モデルが無い倍率をAIで要求した場合はnilを返し、書き出し側が
    // superResolutionModelUnavailableとして失敗できるようにする
    @Test func aiEngineReturnsNilForUnsupportedScale() {
        #expect(ContentViewModel.descriptor(for: .aiSuperResolution, scaleFactor: 3) == nil)
    }
}
