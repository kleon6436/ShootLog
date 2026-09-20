import Foundation
import SwiftData
import Testing

@testable import ShootLog

@MainActor
struct MaskRasterGarbageCollectorTests {

    // MARK: - ヘルパー

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, MaskRaster.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// `rasterIDs` を参照する AI マスクレイヤーを持ち、`orphanCount` 枚の未参照ラスタも抱えた
    /// `DevelopSettings` を作る。
    @discardableResult
    private func makeSettings(
        photoID: UUID = UUID(),
        referencedRasterIDs: [UUID],
        orphanRasterIDs: [UUID],
        in context: ModelContext
    ) throws -> DevelopSettings {
        let settings = DevelopSettings(photoID: photoID)
        context.insert(settings)

        var parameters = DevelopParameters.neutral
        parameters.masks = referencedRasterIDs.map { rasterID in
            MaskLayer(
                id: UUID(),
                name: "ai",
                source: .ai(AIMaskReference(
                    rasterID: rasterID,
                    kind: .foregroundSubject,
                    instanceIndices: [0],
                    visionRevision: 1,
                    bakedLongEdge: 8,
                    bakedAt: .now
                )),
                adjustments: LocalAdjustments()
            )
        }
        try settings.setParameters(parameters)

        for rasterID in referencedRasterIDs + orphanRasterIDs {
            settings.maskRasters.append(MaskRaster(id: rasterID, pngData: Data([0x1]), longEdge: 8))
        }
        try context.save()
        return settings
    }

    // MARK: - テスト

    @Test func collectKeepsReachableRastersAndDeletesOrphans() throws {
        let context = try makeContext()
        let reachable = UUID()
        let orphan = UUID()
        let settings = try makeSettings(
            referencedRasterIDs: [reachable], orphanRasterIDs: [orphan], in: context
        )

        let deleted = MaskRasterGarbageCollector.collect(for: settings, in: context)
        try context.save()

        #expect(deleted == 1)
        #expect(settings.maskRasters.map(\.id) == [reachable])
        let remaining = try context.fetch(FetchDescriptor<MaskRaster>())
        #expect(remaining.map(\.id) == [reachable])
    }

    @Test func collectDeletesNothingWhenAllRastersAreReferenced() throws {
        let context = try makeContext()
        let first = UUID()
        let second = UUID()
        let settings = try makeSettings(
            referencedRasterIDs: [first, second], orphanRasterIDs: [], in: context
        )

        #expect(MaskRasterGarbageCollector.collect(for: settings, in: context) == 0)
        #expect(Set(settings.maskRasters.map(\.id)) == [first, second])
    }

    @Test func collectAllSpansEveryDevelopSettings() throws {
        let context = try makeContext()
        let reachableA = UUID()
        let orphanA = UUID()
        let orphanB = UUID()
        let settingsA = try makeSettings(
            referencedRasterIDs: [reachableA], orphanRasterIDs: [orphanA], in: context
        )
        let settingsB = try makeSettings(
            referencedRasterIDs: [], orphanRasterIDs: [orphanB], in: context
        )

        let deleted = MaskRasterGarbageCollector.collectAll(in: context)

        #expect(deleted == 2)
        #expect(settingsA.maskRasters.map(\.id) == [reachableA])
        #expect(settingsB.maskRasters.isEmpty)
    }

    @Test func collectForPhotoIDLeavesOtherSettingsUntouched() throws {
        let context = try makeContext()
        let targetPhotoID = UUID()
        let orphanOfTarget = UUID()
        let orphanOfOther = UUID()
        let target = try makeSettings(
            photoID: targetPhotoID, referencedRasterIDs: [], orphanRasterIDs: [orphanOfTarget], in: context
        )
        let other = try makeSettings(
            referencedRasterIDs: [], orphanRasterIDs: [orphanOfOther], in: context
        )

        let deleted = MaskRasterGarbageCollector.collect(forPhotoID: targetPhotoID, in: context)

        #expect(deleted == 1)
        #expect(target.maskRasters.isEmpty)
        #expect(other.maskRasters.map(\.id) == [orphanOfOther])
    }

    @Test func collectForUnknownPhotoIDDoesNothing() throws {
        let context = try makeContext()
        let orphan = UUID()
        let settings = try makeSettings(referencedRasterIDs: [], orphanRasterIDs: [orphan], in: context)

        #expect(MaskRasterGarbageCollector.collect(forPhotoID: UUID(), in: context) == 0)
        #expect(settings.maskRasters.map(\.id) == [orphan])
    }
}
