import Foundation
import SwiftData
import Testing

@testable import ShootLog

struct DevelopPresetTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: DevelopPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func initialStateStoresGivenParameters() {
        var params = DevelopParameters.neutral
        params.exposure = 1.5
        let preset = DevelopPreset(name: "Warm", parameters: params, sortIndex: 3)

        #expect(preset.name == "Warm")
        #expect(preset.sortIndex == 3)
        #expect(preset.schemaVersion == 1)
        #expect(preset.parameters.exposure == 1.5)
    }

    @Test func parametersRoundTripThroughBlob() throws {
        var params = DevelopParameters.neutral
        params.contrast = -20
        params.hslSaturation[2] = 40
        params.toneCurveRGB = [
            CurvePoint(x: 0, y: 0.1),
            CurvePoint(x: 0.5, y: 0.6),
            CurvePoint(x: 1, y: 1)
        ]

        let preset = DevelopPreset(name: "P", parameters: .neutral, sortIndex: 0)
        try preset.setParameters(params)

        #expect(preset.parameters == params)
    }

    @Test func corruptedBlobFallsBackToNeutral() {
        let preset = DevelopPreset(name: "P", parameters: .neutral, sortIndex: 0)
        preset.parametersData = Data([0x00, 0x01, 0x02])

        #expect(preset.parameters == .neutral)
    }

    @Test func persistsAndFetchesInSortIndexOrder() throws {
        let context = try makeContext()
        for (index, name) in ["c", "a", "b"].enumerated() {
            context.insert(DevelopPreset(name: name, parameters: .neutral, sortIndex: index))
        }
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<DevelopPreset>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        #expect(fetched.map(\.name) == ["c", "a", "b"])
    }
}
