import Foundation
import SwiftData
import Testing

@testable import ShootLog

struct MaskRasterTests {

    /// インメモリの ModelContext を1つ作る（テストごとに独立）
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: DevelopSettings.self, MaskRaster.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeRaster(longEdge: Int = 1024) -> MaskRaster {
        MaskRaster(id: UUID(), pngData: Data([0x89, 0x50, 0x4E, 0x47]), longEdge: longEdge)
    }

    @Test func insertAndFetchRoundTrips() throws {
        let context = try makeContext()
        let raster = makeRaster()
        let id = raster.id
        context.insert(raster)
        try context.save()

        let all = try context.fetch(FetchDescriptor<MaskRaster>())

        #expect(all.count == 1)
        #expect(all.first?.id == id)
        #expect(all.first?.longEdge == 1024)
        #expect(all.first?.pngData == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func deletingDevelopSettingsCascadesToRasters() throws {
        let context = try makeContext()
        let settings = DevelopSettings(photoID: UUID())
        settings.maskRasters = [makeRaster(), makeRaster(longEdge: 512)]
        context.insert(settings)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<MaskRaster>()).count == 2)

        context.delete(settings)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<MaskRaster>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DevelopSettings>()).isEmpty)
    }

    @Test func deletingRasterLeavesParentIntact() throws {
        let context = try makeContext()
        let settings = DevelopSettings(photoID: UUID())
        let raster = makeRaster()
        settings.maskRasters = [raster]
        context.insert(settings)
        try context.save()

        context.delete(raster)
        try context.save()

        let parents = try context.fetch(FetchDescriptor<DevelopSettings>())
        #expect(parents.count == 1)
        #expect(parents.first?.maskRasters.isEmpty == true)
        #expect(try context.fetch(FetchDescriptor<MaskRaster>()).isEmpty)
    }

    @Test func multipleRastersAttachToSameDevelopSettings() throws {
        let context = try makeContext()
        let settings = DevelopSettings(photoID: UUID())
        context.insert(settings)
        let first = makeRaster(longEdge: 1024)
        let second = makeRaster(longEdge: 2048)
        settings.maskRasters = [first, second]
        try context.save()

        let parents = try context.fetch(FetchDescriptor<DevelopSettings>())
        let rasters = try context.fetch(FetchDescriptor<MaskRaster>())

        #expect(parents.count == 1)
        #expect(parents.first?.maskRasters.count == 2)
        #expect(Set(rasters.map(\.longEdge)) == [1024, 2048])
        #expect(rasters.allSatisfy { $0.developSettings?.photoID == settings.photoID })
    }

    /// blob 側の `AIMaskReference.rasterID` で実体を引けること（参照の紐付け方の確認）。
    @Test func rasterResolvesByReferenceID() throws {
        let context = try makeContext()
        let settings = DevelopSettings(photoID: UUID())
        let raster = makeRaster()
        settings.maskRasters = [raster]
        context.insert(settings)

        var params = DevelopParameters.neutral
        params.masks = [
            MaskLayer(
                id: UUID(),
                name: "subject",
                source: .ai(
                    AIMaskReference(
                        rasterID: raster.id,
                        kind: .foregroundSubject,
                        instanceIndices: [0],
                        visionRevision: 1,
                        bakedLongEdge: 1024,
                        bakedAt: .now
                    )
                ),
                adjustments: LocalAdjustments()
            )
        ]
        try settings.setParameters(params)
        try context.save()

        let stored = try #require(try context.fetch(FetchDescriptor<DevelopSettings>()).first)
        guard case let .ai(reference) = try #require(stored.parameters.masks.first).source else {
            Issue.record("AI マスクとして復元されなかった")
            return
        }

        #expect(stored.maskRasters.first(where: { $0.id == reference.rasterID }) != nil)
    }
}
