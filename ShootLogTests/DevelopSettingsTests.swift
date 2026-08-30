import Foundation
import SwiftData
import Testing

@testable import ShootLog

struct DevelopSettingsTests {

    /// インメモリの ModelContainer を1つ作る（テストごとに独立）
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: DevelopSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - 初期状態

    @Test func initialStateIsNeutral() {
        let settings = DevelopSettings(photoID: UUID())

        #expect(DevelopSettings.currentSchemaVersion == 3)
        #expect(settings.schemaVersion == DevelopSettings.currentSchemaVersion)
        #expect(settings.usesRAWParameterMapping)
        #expect(settings.usesManualLensCorrection)
        #expect(settings.parameters == .neutral)
        #expect(!settings.parametersData.isEmpty)
    }

    @Test func version2KeepsRAWMappingButDisablesManualLensCorrection() {
        let settings = DevelopSettings(photoID: UUID())
        settings.schemaVersion = 2

        #expect(settings.usesRAWParameterMapping)
        #expect(settings.usesManualLensCorrection == false)
    }

    // MARK: - パラメータの往復

    @Test func parametersRoundTripThroughBlob() {
        let settings = DevelopSettings(photoID: UUID())

        var edited = DevelopParameters.neutral
        edited.exposure = 1.25
        edited.contrast = -40
        edited.hslSaturation[2] = 60
        edited.toneCurveRGB = [
            CurvePoint(x: 0, y: 0.1),
            CurvePoint(x: 0.5, y: 0.4),
            CurvePoint(x: 1, y: 1)
        ]

        settings.parameters = edited

        #expect(settings.parameters == edited)
    }

    @Test func settingParametersAdvancesUpdatedAt() {
        let settings = DevelopSettings(photoID: UUID())
        // 過去の値をあえて入れ、set が .now で必ず前へ進めることを確認する
        let past = Date(timeIntervalSince1970: 0)
        settings.updatedAt = past

        var edited = DevelopParameters.neutral
        edited.exposure = 0.5
        settings.parameters = edited

        #expect(settings.updatedAt > past)
    }

    // MARK: - 破損 blob 耐性

    @Test func corruptedBlobFallsBackToNeutral() {
        let settings = DevelopSettings(photoID: UUID())
        settings.parametersData = Data([0xFF])

        #expect(settings.parameters == .neutral)
    }

    @Test func encodedNeutralDecodesToNeutral() throws {
        let data = DevelopSettings.encodedNeutral()
        #expect(!data.isEmpty)

        let decoded = try JSONDecoder().decode(DevelopParameters.self, from: data)
        #expect(decoded == .neutral)
    }

    // MARK: - 永続化

    @Test func insertAndFetchRoundTrips() throws {
        let context = try makeContext()
        let photoID = UUID()

        let settings = DevelopSettings(photoID: photoID)
        var edited = DevelopParameters.neutral
        edited.vibrance = 33
        settings.parameters = edited
        context.insert(settings)
        try context.save()

        let all = try context.fetch(FetchDescriptor<DevelopSettings>())
        let match = all.first(where: { $0.photoID == photoID })

        #expect(all.count == 1)
        #expect(match?.parameters.vibrance == 33)
    }

    @Test func fetchByPhotoIDReturnsSingleRow() throws {
        let context = try makeContext()
        let photoID = UUID()
        context.insert(DevelopSettings(photoID: photoID))
        context.insert(DevelopSettings(photoID: UUID()))
        try context.save()

        let all = try context.fetch(FetchDescriptor<DevelopSettings>())
        let matches = all.filter { $0.photoID == photoID }

        #expect(matches.count == 1)
    }
}

// MARK: - ContentViewModel 拡張

@MainActor
struct ContentViewModelDevelopTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// context に写真を1件挿入し、選択済みの ViewModel を返す
    private func makeViewModel() throws -> (ContentViewModel, ModelContext, Photo) {
        let context = ModelContext(try makeContainer())
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/develop-test.jpg"))
        context.insert(photo)
        try context.save()

        let viewModel = ContentViewModel()
        viewModel.modelContext = context
        viewModel.selectedPhoto = photo
        return (viewModel, context, photo)
    }

    @Test func updateCreatesRowForNonNeutralParameters() throws {
        let (viewModel, context, photo) = try makeViewModel()

        var params = DevelopParameters.neutral
        params.exposure = 0.75
        viewModel.updateDevelopParameters(params)

        #expect(viewModel.currentDevelopSettings != nil)

        let rows = try context.fetch(FetchDescriptor<DevelopSettings>())
        #expect(rows.count == 1)
        #expect(rows.first?.photoID == photo.id)
        #expect(rows.first?.parameters.exposure == 0.75)
    }

    @Test func updateWithNeutralDeletesExistingRow() throws {
        let (viewModel, context, _) = try makeViewModel()

        var params = DevelopParameters.neutral
        params.contrast = 20
        viewModel.updateDevelopParameters(params)
        #expect(viewModel.currentDevelopSettings != nil)

        viewModel.updateDevelopParameters(.neutral)

        #expect(viewModel.currentDevelopSettings == nil)
        let rows = try context.fetch(FetchDescriptor<DevelopSettings>())
        #expect(rows.isEmpty)
    }

    @Test func repeatedUpdateReusesSameRow() throws {
        let (viewModel, context, _) = try makeViewModel()

        var params = DevelopParameters.neutral
        params.saturation = 10
        viewModel.updateDevelopParameters(params)
        params.saturation = 40
        viewModel.updateDevelopParameters(params)

        let rows = try context.fetch(FetchDescriptor<DevelopSettings>())
        #expect(rows.count == 1)
        #expect(rows.first?.parameters.saturation == 40)
    }

    /// 既存行がストアにあるが currentDevelopSettings が未ロードの状態（前回セッションで
    /// 保存済み・ViewModel は作り直し）で update すると、重複行を作らず既存行を再利用する
    @Test func updateReusesStoredRowWhenNotYetLoaded() throws {
        let (viewModel, context, photo) = try makeViewModel()

        let existing = DevelopSettings(photoID: photo.id)
        var stored = DevelopParameters.neutral
        stored.exposure = 0.2
        existing.parameters = stored
        context.insert(existing)
        try context.save()

        // loadDevelopSettings を経ずに直接 update（スライダー操作を模す）
        viewModel.currentDevelopSettings = nil
        var params = DevelopParameters.neutral
        params.exposure = 1.0
        viewModel.updateDevelopParameters(params)

        let rows = try context.fetch(FetchDescriptor<DevelopSettings>())
        #expect(rows.count == 1)
        #expect(rows.first?.parameters.exposure == 1.0)
    }

    @Test func loadDevelopSettingsPicksMatchingPhoto() throws {
        let (viewModel, context, photo) = try makeViewModel()

        let mine = DevelopSettings(photoID: photo.id)
        var params = DevelopParameters.neutral
        params.tint = 15
        mine.parameters = params
        context.insert(mine)
        context.insert(DevelopSettings(photoID: UUID()))
        try context.save()

        viewModel.currentDevelopSettings = nil
        viewModel.loadDevelopSettings(for: photo)

        #expect(viewModel.currentDevelopSettings?.photoID == photo.id)
        #expect(viewModel.currentDevelopSettings?.parameters.tint == 15)
    }

    @Test func resetDevelopRemovesRow() throws {
        let (viewModel, context, _) = try makeViewModel()

        var params = DevelopParameters.neutral
        params.blacks = -30
        viewModel.updateDevelopParameters(params)
        #expect(viewModel.currentDevelopSettings != nil)

        viewModel.resetDevelop()

        #expect(viewModel.currentDevelopSettings == nil)
        #expect(try context.fetch(FetchDescriptor<DevelopSettings>()).isEmpty)
    }
}
