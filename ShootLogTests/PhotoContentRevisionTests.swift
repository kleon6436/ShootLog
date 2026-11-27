import AppKit
import Foundation
import Observation
import Testing

@testable import ShootLog

// 派生配列のメモ（.omc/plans/macos27-optimization.md 2-3）の回帰テスト。
// メモは photoContentRevision と絞り込みの入力を鍵にするため、Photo を変える経路ごとに
// revision が進み、一覧が古いまま残らないことを確かめる
@MainActor
struct PhotoContentRevisionTests {

    // MARK: - 絞り込みの入力ごとの回帰テスト

    @Test func togglingFavoriteWhileFavoritesOnlyUpdatesLists() {
        let (content, sidebar) = makeViewModels()
        let favorite = makePhoto("favorite.jpg")
        favorite.isFavorite = true
        let other = makePhoto("other.jpg")
        content.photos = [favorite, other]
        content.showFavoritesOnly = true
        #expect(sidebar.displayedPhotos.map(\.id) == [favorite.id])
        #expect(content.visiblePhotos.map(\.id) == [favorite.id])

        content.toggleFavorite(other)
        #expect(sidebar.displayedPhotos.map(\.id) == [favorite.id, other.id])
        #expect(content.visiblePhotos.map(\.id) == [favorite.id, other.id])

        content.toggleFavorite(favorite)
        #expect(sidebar.displayedPhotos.map(\.id) == [other.id])
        #expect(content.visiblePhotos.map(\.id) == [other.id])
    }

    @Test func exifArrivingDuringCameraSearchShowsPhoto() {
        let (content, sidebar) = makeViewModels()
        let photo = makePhoto("DSC_0001.NEF")
        content.photos = [photo, makePhoto("DSC_0002.NEF")]
        sidebar.searchText = "Z8"
        #expect(sidebar.displayedPhotos.isEmpty)

        content.apply(EXIFInfo(cameraModel: "Nikon Z8"), to: photo)

        #expect(sidebar.displayedPhotos.map(\.id) == [photo.id])
    }

    @Test func aiResultWhileCategoryFilterIsActiveUpdatesList() {
        let (content, sidebar) = makeViewModels()
        let photo = makePhoto("reanalyzed.jpg")
        photo.aiCategoryRawValues = [AISubjectCategory.animal.rawValue]
        content.photos = [photo]
        sidebar.selectedAICategories = [.person]
        #expect(sidebar.displayedPhotos.isEmpty)

        content.apply(VisionLabelClassification(categories: [.person], rawIdentifiers: ["people"]), to: photo)

        #expect(sidebar.displayedPhotos.map(\.id) == [photo.id])
    }

    // 再解析の経路（生成器 → onResult → MainActor での反映）を通しても一覧が追随すること
    @Test func singlePhotoReanalysisWhileCategoryFilterIsActiveUpdatesList() async {
        let (content, sidebar) = makeViewModels()
        let photo = makePhoto("reanalysis-flow.jpg")
        photo.aiCategoryRawValues = [AISubjectCategory.animal.rawValue]
        photo.aiLabelingFetchedAt = Date(timeIntervalSinceNow: -3600)
        photo.aiLabelingSchemaVersion = AILabelingGenerator.currentSchemaVersion
        photo.aiDiagnosisFetchedAt = Date(timeIntervalSinceNow: -3600)
        photo.aiDiagnosisSchemaVersion = PhotoQualityDiagnosisGenerator.currentSchemaVersion
        content.photos = [photo]
        content.aiLabelingGenerator = AILabelingGenerator(
            imageProvider: StubImageProvider(),
            classifier: StubPersonClassifier()
        )
        content.qualityDiagnosisGenerator = PhotoQualityDiagnosisGenerator(
            imageProvider: StubImageProvider(),
            diagnoser: StubDiagnoser()
        )
        sidebar.selectedAICategories = [.person]
        #expect(sidebar.displayedPhotos.isEmpty)

        content.reanalyzeAI([photo])

        #expect(await wait { sidebar.displayedPhotos.map(\.id) == [photo.id] })
    }

    @Test func captionArrivingDuringSearchShowsPhoto() {
        let (content, sidebar) = makeViewModels()
        let photo = makePhoto("IMG_0001.jpg")
        content.photos = [photo]
        sidebar.searchText = "beach"
        #expect(sidebar.displayedPhotos.isEmpty)

        content.applyCaption("A dog running on the beach", to: photo)

        #expect(sidebar.displayedPhotos.map(\.id) == [photo.id])
    }

    // フォルダ切替で件数が同じ別の配列に差し替わっても、古い一覧・位置を返さないこと
    @Test func replacingPhotosWithSameCountRecomputesLists() {
        let (content, sidebar) = makeViewModels()
        let oldPhotos = [makePhoto("a.jpg"), makePhoto("b.jpg")]
        content.photos = oldPhotos
        content.selectedPhoto = oldPhotos[1]
        #expect(sidebar.displayedPhotos.map(\.id) == oldPhotos.map(\.id))
        #expect(content.visiblePhotos.map(\.id) == oldPhotos.map(\.id))
        #expect(content.selectedIndex == 1)
        #expect(sidebar.displayedIndex == 1)

        let newPhotos = [makePhoto("c.jpg"), makePhoto("d.jpg")]
        content.photos = newPhotos
        content.selectedPhoto = newPhotos[0]

        #expect(sidebar.displayedPhotos.map(\.id) == newPhotos.map(\.id))
        #expect(content.visiblePhotos.map(\.id) == newPhotos.map(\.id))
        #expect(content.selectedIndex == 0)
        #expect(sidebar.displayedIndex == 0)
        #expect(content.visibleIndex == 0)
    }

    // 段階挿入（photos.append(contentsOf:)）の途中で検索しても、後から届いたチャンクが反映されること
    @Test func searchDuringStagedInsertionIncludesLaterChunks() {
        let (content, sidebar) = makeViewModels()
        let firstBatch = [makePhoto("beach-1.jpg"), makePhoto("city-1.jpg")]
        content.photos = firstBatch
        sidebar.searchText = "beach"
        #expect(sidebar.displayedPhotos.map(\.id) == [firstBatch[0].id])

        let chunk = [makePhoto("beach-2.jpg"), makePhoto("city-2.jpg")]
        content.photos.append(contentsOf: chunk)

        #expect(sidebar.displayedPhotos.map(\.id) == [firstBatch[0].id, chunk[0].id])
    }

    @Test func failedAnalysisListFollowsAIResults() {
        let (content, _) = makeViewModels()
        let photo = makePhoto("failed.jpg")
        content.photos = [photo]
        #expect(content.aiAnalysisFailedPhotos.isEmpty)

        content.apply(nil as VisionLabelClassification?, to: photo)
        #expect(content.aiAnalysisFailedPhotos.map(\.id) == [photo.id])

        content.apply(VisionLabelClassification(categories: [.person], rawIdentifiers: []), to: photo)
        #expect(content.aiAnalysisFailedPhotos.isEmpty)
    }

    // MARK: - 変更関数ごとに revision が進むこと

    @Test func photoMutationFunctionsBumpTheMatchingRevisions() {
        let (content, _) = makeViewModels()
        let photo = makePhoto("mutations.jpg")

        expectBump(\.photosArrayRevision, content) { content.photos = [photo] }
        // 同じ内容・同じ件数の差し替えでも進める
        expectBump(\.photosArrayRevision, content) { content.photos = [photo] }
        expectBump(\.photosArrayRevision, content) { content.photos.append(makePhoto("appended.jpg")) }

        expectBump(\.photoContentRevision, content) { content.apply(EXIFInfo(cameraModel: "Camera"), to: photo) }
        expectBump(\.analysisRevision, content) { content.apply(EXIFInfo(cameraModel: "Camera"), to: photo) }
        expectBump(\.photoContentRevision, content) { content.toggleFavorite(photo) }
        expectBump(\.photoContentRevision, content) { content.applyCaption("caption", to: photo) }
        expectBump(\.photoContentRevision, content) {
            content.apply(VisionLabelClassification(categories: [.animal], rawIdentifiers: []), to: photo)
        }
        // 再解析が失敗し、旧スキーマ版の分類結果を消す経路
        photo.aiLabelingSchemaVersion = AILabelingGenerator.currentSchemaVersion - 1
        let before = (content.photoContentRevision, content.aiFailureRevision, content.analysisRevision)
        content.apply(nil as VisionLabelClassification?, to: photo)
        #expect(content.photoContentRevision > before.0)
        #expect(content.aiFailureRevision > before.1)
        #expect(content.analysisRevision > before.2)
        #expect(photo.aiCategoryRawValues.isEmpty)
        #expect(photo.aiLabelingFailedAt != nil)
    }

    // 値が変わらない反映では一覧の入力の番号を進めない（絞り込み中に結果が届くたびの作り直しを避ける）
    @Test func unchangedFilterValuesDoNotBumpContentRevision() {
        let (content, _) = makeViewModels()
        let photo = makePhoto("unchanged.jpg")
        photo.cameraModel = "Camera"
        photo.aiCategoryRawValues = [AISubjectCategory.person.rawValue]
        photo.aiCaptionText = "caption"
        content.photos = [photo]

        expectNoBump(\.photoContentRevision, content) { content.apply(EXIFInfo(cameraModel: "Camera"), to: photo) }
        expectNoBump(\.photoContentRevision, content) {
            content.apply(VisionLabelClassification(categories: [.person], rawIdentifiers: ["people"]), to: photo)
        }
        expectNoBump(\.photoContentRevision, content) { content.applyCaption("caption", to: photo) }
        // 成功要因タグは一覧の絞り込みに使わない
        expectNoBump(\.photoContentRevision, content) { content.toggleSuccessTag(.light, for: photo) }
    }

    // 画質診断の反映は private のため、生成器を通して確かめる。
    // 失敗の記録は一括再解析の対象を変えるが、診断スコアは一覧の絞り込みに使わない
    @Test(arguments: [true, false])
    func qualityDiagnosisResultBumpsOnlyFailureRevision(succeeds: Bool) async {
        let (content, _) = makeViewModels()
        let photo = makePhoto("diagnosis-\(succeeds).jpg")
        content.photos = [photo]
        content.qualityDiagnosisGenerator = PhotoQualityDiagnosisGenerator(
            imageProvider: StubImageProvider(providesImage: succeeds),
            diagnoser: StubDiagnoser()
        )
        let contentBefore = content.photoContentRevision
        let failureBefore = content.aiFailureRevision

        let token = content.beginAIQualityDiagnosis()
        await content.startAIQualityDiagnosis(token: token, around: nil)

        #expect(await wait { content.aiQualityDiagnosisCompletedCount == 1 })
        #expect(content.photoContentRevision == contentBefore)
        #expect((content.aiFailureRevision > failureBefore) == !succeeds)
        #expect(content.aiAnalysisFailedPhotos.isEmpty == succeeds)
    }

    // 絞り込みが無効な一覧は Photo の値を読まないため、背景の結果が届いても再描画させない
    @Test func backgroundResultsDoNotInvalidateUnfilteredLists() {
        let (content, sidebar) = makeViewModels()
        let photo = makePhoto("unfiltered.jpg")
        content.photos = [photo, makePhoto("other.jpg")]
        content.selectedPhoto = photo

        let didChange = ChangeFlag()
        withObservationTracking {
            _ = sidebar.displayedPhotos
            _ = sidebar.displayedIndex
            _ = content.visiblePhotos
            _ = content.visibleIndex
            _ = content.selectedIndex
        } onChange: {
            didChange.value = true
        }

        content.apply(EXIFInfo(cameraModel: "Nikon Z8"), to: photo)
        content.apply(VisionLabelClassification(categories: [.person], rawIdentifiers: []), to: photo)
        content.applyCaption("A dog on the beach", to: photo)

        #expect(!didChange.value)
    }

    @Test func filteredListsObserveBackgroundResults() {
        let (content, sidebar) = makeViewModels()
        let photo = makePhoto("filtered.jpg")
        content.photos = [photo]
        sidebar.searchText = "Z8"

        let didChange = ChangeFlag()
        withObservationTracking {
            _ = sidebar.displayedPhotos
        } onChange: {
            didChange.value = true
        }

        content.apply(EXIFInfo(cameraModel: "Nikon Z8"), to: photo)

        #expect(didChange.value)
    }

    // MARK: - 位置とキー送り

    @Test func displayedIndexAndKeyNavigationFollowFilteredList() {
        let (content, sidebar) = makeViewModels()
        let photos = (0..<5).map { makePhoto("nav-\($0).jpg") }
        for index in [0, 2, 4] { photos[index].isFavorite = true }
        content.photos = photos
        content.showFavoritesOnly = true

        // 未選択なら先頭を選ぶ
        #expect(sidebar.displayedIndex == nil)
        sidebar.selectNext()
        #expect(content.selectedPhoto?.id == photos[0].id)
        #expect(sidebar.displayedIndex == 0)

        sidebar.selectNext()
        #expect(content.selectedPhoto?.id == photos[2].id)
        #expect(sidebar.displayedIndex == 1)
        #expect(content.visibleIndex == 1)
        #expect(content.selectedIndex == 2)

        sidebar.selectNext()
        sidebar.selectNext()  // 末尾でクランプする
        #expect(content.selectedPhoto?.id == photos[4].id)
        #expect(sidebar.displayedIndex == 2)

        sidebar.selectPrevious()
        #expect(content.selectedPhoto?.id == photos[2].id)
        sidebar.selectPrevious()
        sidebar.selectPrevious()  // 先頭でクランプする
        #expect(content.selectedPhoto?.id == photos[0].id)

        // 絞り込みから外れた写真を選んでいるときは位置を出さず、キー送りは先頭へ戻る
        content.selectedPhoto = photos[1]
        #expect(sidebar.displayedIndex == nil)
        #expect(content.visibleIndex == nil)
        sidebar.selectPrevious()
        #expect(content.selectedPhoto?.id == photos[0].id)
    }

    @Test func contentKeyNavigationUsesVisiblePhotos() {
        let (content, _) = makeViewModels()
        let photos = (0..<3).map { makePhoto("visible-\($0).jpg") }
        photos[0].isFavorite = true
        photos[2].isFavorite = true
        content.photos = photos
        content.showFavoritesOnly = true
        content.selectedPhoto = photos[0]

        content.selectNext()
        #expect(content.selectedPhoto?.id == photos[2].id)
        content.selectPrevious()
        #expect(content.selectedPhoto?.id == photos[0].id)
    }

    // MARK: - 外部アプリ一覧

    @Test func externalAppsAreRecomputedWhenIntegrationSettingsChange() {
        let (content, _) = makeViewModels()
        let finderID = FinderAdapter().id

        content.updateIntegrationSettings([])
        #expect(content.externalApps.contains { $0.id == finderID })

        let disabledFinder = IntegrationAppSetting(identifier: finderID, isEnabled: false, sortOrder: 0, isCustom: false)
        content.updateIntegrationSettings([disabledFinder])
        #expect(!content.externalApps.contains { $0.id == finderID })
    }

    // 設定画面は同じ IntegrationAppSetting をその場で書き換える。ContentView は値の一覧の変化で
    // updateIntegrationSettings を呼ぶので、その一覧が変わり、同じ配列を渡し直すと一覧が追随すること
    @Test func inPlaceSettingEditChangesValuesAndExternalAppsFollow() {
        let (content, _) = makeViewModels()
        let finderID = FinderAdapter().id
        let setting = IntegrationAppSetting(identifier: finderID, isEnabled: true, sortOrder: 0, isCustom: false)
        let settings = [setting]
        content.updateIntegrationSettings(settings)
        let valuesBefore = ContentViewModel.integrationSettingValues(settings)
        #expect(content.externalApps.contains { $0.id == finderID })

        setting.isEnabled = false

        #expect(ContentViewModel.integrationSettingValues(settings) != valuesBefore)
        content.updateIntegrationSettings(settings)
        #expect(!content.externalApps.contains { $0.id == finderID })
    }

    // MARK: - Helpers

    private func makeViewModels() -> (ContentViewModel, SidebarViewModel) {
        let content = ContentViewModel()
        return (content, SidebarViewModel(content: content))
    }

    private func makePhoto(_ name: String) -> Photo {
        Photo(fileURL: URL(fileURLWithPath: "/tmp/revision-\(UUID().uuidString)/\(name)"))
    }

    private func expectBump(
        _ revision: KeyPath<ContentViewModel, Int>,
        _ content: ContentViewModel,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ mutation: () -> Void
    ) {
        let before = content[keyPath: revision]
        mutation()
        #expect(content[keyPath: revision] > before, sourceLocation: sourceLocation)
    }

    private func expectNoBump(
        _ revision: KeyPath<ContentViewModel, Int>,
        _ content: ContentViewModel,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ mutation: () -> Void
    ) {
        let before = content[keyPath: revision]
        mutation()
        #expect(content[keyPath: revision] == before, sourceLocation: sourceLocation)
    }

    // 生成器の結果はバックグラウンドの Task から MainActor へ戻って反映されるため、条件成立をポーリングで待つ
    private func wait(until condition: @MainActor () -> Bool) async -> Bool {
        // 負荷の高い CI でも誤って失敗しないよう、上限を約10秒にする
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

// withObservationTracking の onChange は @Sendable のため、参照型で結果を受け取る
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private struct StubImageProvider: AILabelingImageProviding {
    var providesImage = true

    func thumbnail(for _: AILabelingTarget) async -> NSImage? {
        providesImage ? NSImage(size: NSSize(width: 1, height: 1)) : nil
    }
}

private struct StubPersonClassifier: AILabelingClassifying {
    func classify(_: NSImage) -> VisionLabelClassification? {
        VisionLabelClassification(categories: [.person], rawIdentifiers: ["people"])
    }
}

private struct StubDiagnoser: PhotoQualityDiagnosing {
    func diagnose(_: NSImage) -> PhotoQualityDiagnosis? {
        PhotoQualityDiagnosis(
            aestheticsScore: 0.5,
            isUtility: false,
            faceQualityScore: nil,
            exposureBias: 0,
            sharpnessScore: nil,
            compositionOffsetScore: nil
        )
    }
}
