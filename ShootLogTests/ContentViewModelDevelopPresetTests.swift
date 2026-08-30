import Foundation
import SwiftData
import Testing

@testable import ShootLog

@MainActor
struct ContentViewModelDevelopPresetTests {

    private func makeContentViewModel() throws -> (ContentViewModel, ModelContext) {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let content = ContentViewModel()
        content.modelContext = context
        return (content, context)
    }

    private func adjusted(_ exposure: Double) -> DevelopParameters {
        var params = DevelopParameters.neutral
        params.exposure = exposure
        return params
    }

    @Test func savePersistsPresetAndReloads() throws {
        let (content, _) = try makeContentViewModel()

        let preset = content.saveDevelopPreset(name: "Punchy", from: adjusted(1.0))

        #expect(preset != nil)
        #expect(content.developPresets.count == 1)
        #expect(content.developPresets.first?.name == "Punchy")
        #expect(content.developPresets.first?.parameters.exposure == 1.0)
    }

    @Test func emptyNameFallsBackToDefault() throws {
        let (content, _) = try makeContentViewModel()

        content.saveDevelopPreset(name: "   ", from: adjusted(0.5))

        #expect(content.developPresets.first?.name == String(localized: "develop.preset.defaultName"))
    }

    @Test func sortIndexIncrementsWithEachSave() throws {
        let (content, _) = try makeContentViewModel()

        content.saveDevelopPreset(name: "A", from: adjusted(0.1))
        content.saveDevelopPreset(name: "B", from: adjusted(0.2))
        content.saveDevelopPreset(name: "C", from: adjusted(0.3))

        #expect(content.developPresets.map(\.sortIndex) == [0, 1, 2])
        #expect(content.developPresets.map(\.name) == ["A", "B", "C"])
    }

    @Test func deleteRemovesPreset() throws {
        let (content, _) = try makeContentViewModel()
        content.saveDevelopPreset(name: "A", from: adjusted(0.1))
        content.saveDevelopPreset(name: "B", from: adjusted(0.2))

        let toDelete = try #require(content.developPresets.first { $0.name == "A" })
        content.deleteDevelopPreset(toDelete)

        #expect(content.developPresets.map(\.name) == ["B"])
    }

    @Test func renameUpdatesName() throws {
        let (content, _) = try makeContentViewModel()
        content.saveDevelopPreset(name: "Old", from: adjusted(0.1))
        let preset = try #require(content.developPresets.first)

        content.renameDevelopPreset(preset, to: "New")
        #expect(content.developPresets.first?.name == "New")

        // 空白のみのリネームは無視する
        content.renameDevelopPreset(preset, to: "   ")
        #expect(content.developPresets.first?.name == "New")
    }

    @Test func presetsLoadFreshInstanceViaLoadDevelopPresets() throws {
        let (content, context) = try makeContentViewModel()
        context.insert(DevelopPreset(name: "External", parameters: adjusted(2.0), sortIndex: 0))
        try context.save()

        #expect(content.developPresets.isEmpty)
        content.loadDevelopPresets()
        #expect(content.developPresets.map(\.name) == ["External"])
    }
}
