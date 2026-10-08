import AppKit
import Foundation
import Testing

@testable import ShootLog

@MainActor
struct ContentViewModelQualityDiagnosisTests {

    @Test func imageResolutionFailureIsRecordedAndNotRetriedOnNextOpen() async {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/quality-diagnosis-unresolved.jpg"))
        let content = ContentViewModel()
        content.photos = [photo]
        content.qualityDiagnosisGenerator = PhotoQualityDiagnosisGenerator(
            imageProvider: StubQualityImageProvider(providesImage: false),
            diagnoser: StubQualityDiagnoser(result: nil)
        )

        let token = content.beginAIQualityDiagnosis()
        await content.startAIQualityDiagnosis(token: token, around: nil)

        #expect(await wait { content.aiQualityDiagnosisCompletedCount == 1 })
        #expect(photo.aiDiagnosisFetchedAt == nil)
        #expect(photo.aiDiagnosisFailedAt != nil)
        #expect(photo.aiDiagnosisSchemaVersion == PhotoQualityDiagnosisGenerator.currentSchemaVersion)
        // 同じファイルのまま再訪しても、失敗した写真を処理し直さない
        #expect(content.aiQualityDiagnosisTargetPhotos().isEmpty)
    }

    @Test func successAfterFailureClearsFailureMark() async {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/quality-diagnosis-recovered.jpg"))
        photo.aiDiagnosisFailedAt = Date(timeIntervalSinceNow: -60)
        photo.aiDiagnosisSchemaVersion = PhotoQualityDiagnosisGenerator.currentSchemaVersion - 1
        let content = ContentViewModel()
        content.photos = [photo]
        content.qualityDiagnosisGenerator = PhotoQualityDiagnosisGenerator(
            imageProvider: StubQualityImageProvider(providesImage: true),
            diagnoser: StubQualityDiagnoser(result: PhotoQualityDiagnosis(
                aestheticsScore: 0.5,
                isUtility: false,
                faceQualityScore: nil,
                exposureBias: 0,
                sharpnessScore: nil,
                compositionOffsetScore: nil
            ))
        )

        let token = content.beginAIQualityDiagnosis()
        await content.startAIQualityDiagnosis(token: token, around: nil)

        #expect(await wait { photo.aiDiagnosisFetchedAt != nil })
        #expect(photo.aiDiagnosisFailedAt == nil)
    }

    // MARK: - 失敗した写真の再試行条件（被写体認識・画質診断で共通）

    @Test func failedFolderPhotoIsRetriedOnlyAfterFileChanges() {
        let url = URL(fileURLWithPath: "/tmp/ai-failure-folder.jpg")
        let failedAt = Date(timeIntervalSinceNow: -3600)
        let photo = Photo(fileURL: url)
        photo.aiLabelingFailedAt = failedAt
        photo.aiLabelingSchemaVersion = AILabelingGenerator.currentSchemaVersion
        let content = ContentViewModel()
        content.photos = [photo]

        content.fileAttributesSnapshots = [
            url: FileAttributesSnapshot(size: 1, modificationDate: failedAt.addingTimeInterval(-60), creationDate: nil)
        ]
        #expect(content.aiLabelingTargetPhotos().isEmpty)

        content.fileAttributesSnapshots = [
            url: FileAttributesSnapshot(size: 1, modificationDate: failedAt.addingTimeInterval(60), creationDate: nil)
        ]
        #expect(content.aiLabelingTargetPhotos().count == 1)
    }

    @Test func failedPhotoIsRetriedWhenSchemaVersionIsBumped() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/ai-failure-schema.jpg"))
        photo.aiLabelingFailedAt = Date()
        photo.aiLabelingSchemaVersion = AILabelingGenerator.currentSchemaVersion - 1
        let content = ContentViewModel()
        content.photos = [photo]

        #expect(content.aiLabelingTargetPhotos().count == 1)
    }

    @Test func failedPhotosLibraryPhotoIsRetriedAfterInterval() {
        let photo = Photo(
            fileURL: URL(fileURLWithPath: "/tmp/ai-failure-icloud.jpg"),
            phAssetLocalIdentifier: "ai-failure-icloud"
        )
        let failedAt = Date()
        photo.aiDiagnosisFailedAt = failedAt
        photo.aiDiagnosisSchemaVersion = PhotoQualityDiagnosisGenerator.currentSchemaVersion
        let content = ContentViewModel()
        content.photos = [photo]

        #expect(content.aiQualityDiagnosisTargetPhotos(now: failedAt.addingTimeInterval(60)).isEmpty)
        #expect(
            content.aiQualityDiagnosisTargetPhotos(
                now: failedAt.addingTimeInterval(ContentViewModel.aiFailureRetryInterval)
            ).count == 1
        )
    }

    @Test func partialVisionResultStillMarksPhotoAsDiagnosed() async {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/quality-diagnosis-partial.jpg"))
        let content = ContentViewModel()
        content.photos = [photo]
        // Vision が一部スコアしか返せなかったケース（画像自体は解決できている）
        let partial = PhotoQualityDiagnosis(
            aestheticsScore: nil,
            isUtility: false,
            faceQualityScore: nil,
            exposureBias: -0.5,
            sharpnessScore: nil,
            compositionOffsetScore: nil
        )
        content.qualityDiagnosisGenerator = PhotoQualityDiagnosisGenerator(
            imageProvider: StubQualityImageProvider(providesImage: true),
            diagnoser: StubQualityDiagnoser(result: partial)
        )

        let token = content.beginAIQualityDiagnosis()
        await content.startAIQualityDiagnosis(token: token, around: nil)

        #expect(await wait { photo.aiDiagnosisFetchedAt != nil })
        #expect(photo.aiExposureBias == -0.5)
        #expect(photo.aiAestheticsOverallScore == nil)
        #expect(photo.aiDiagnosisSchemaVersion == PhotoQualityDiagnosisGenerator.currentSchemaVersion)
    }

    // MARK: - 手動の再解析

    @Test func reanalysisRerunsAlreadyAnalyzedAndFailedPhotos() async {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/ai-reanalysis-target.jpg"))
        let previousDiagnosisDate = Date(timeIntervalSinceNow: -3600)
        photo.aiDiagnosisFetchedAt = previousDiagnosisDate
        photo.aiDiagnosisSchemaVersion = PhotoQualityDiagnosisGenerator.currentSchemaVersion
        photo.aiLabelingFailedAt = Date(timeIntervalSinceNow: -3600)
        photo.aiLabelingSchemaVersion = AILabelingGenerator.currentSchemaVersion
        let content = ContentViewModel()
        content.photos = [photo]
        content.aiLabelingGenerator = AILabelingGenerator(
            imageProvider: StubQualityImageProvider(providesImage: true),
            classifier: StubLabelingClassifier()
        )
        content.qualityDiagnosisGenerator = PhotoQualityDiagnosisGenerator(
            imageProvider: StubQualityImageProvider(providesImage: true),
            diagnoser: StubQualityDiagnoser(result: Self.neutralDiagnosis)
        )
        // 通常の対象判定では、どちらも処理済み・再試行不要の扱い
        #expect(content.aiLabelingTargetPhotos().isEmpty)
        #expect(content.aiQualityDiagnosisTargetPhotos().isEmpty)

        content.reanalyzeAI([photo])

        #expect(await wait {
            photo.aiLabelingFetchedAt != nil
                && (photo.aiDiagnosisFetchedAt ?? .distantPast) > previousDiagnosisDate
        })
        #expect(photo.aiLabelingFailedAt == nil)
        #expect(photo.aiCategoryRawValues == [AISubjectCategory.person.rawValue])
        #expect(content.aiLabelingReanalysisURLs.isEmpty)
        #expect(content.aiQualityDiagnosisReanalysisURLs.isEmpty)
        #expect(content.aiAnalysisFailedPhotos.isEmpty)
    }

    @Test func reanalysisDuringStagingOnlyQueuesPhotos() async {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/ai-reanalysis-staging.jpg"))
        photo.aiLabelingFetchedAt = Date()
        photo.aiLabelingSchemaVersion = AILabelingGenerator.currentSchemaVersion
        let content = ContentViewModel()
        content.photos = [photo]
        let staging = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        content.photoStagingTask = staging
        defer { staging.cancel() }
        let tokenBefore = content.aiLabelingToken

        content.reanalyzeAI([photo])

        // フォルダ読み込み側の解析を止めないよう世代は進めず、開始時に拾わせる
        #expect(content.aiLabelingToken == tokenBefore)
        #expect(content.aiLabelingTargetPhotos().map(\.fileURL) == [photo.fileURL])
        #expect(content.aiQualityDiagnosisTargetPhotos().map(\.fileURL) == [photo.fileURL])
    }

    @Test func prioritizingMovesRequestedPhotosFirstAndKeepsOrder() {
        let photos = (0..<5).map { Photo(fileURL: URL(fileURLWithPath: "/tmp/ai-priority-\($0).jpg")) }
        let requested: Set<URL> = [photos[3].fileURL, photos[1].fileURL]

        let ordered = ContentViewModel.prioritizing(requested, in: photos)

        #expect(ordered.map(\.fileURL) == [1, 3, 0, 2, 4].map { photos[$0].fileURL })
    }

    private static let neutralDiagnosis = PhotoQualityDiagnosis(
        aestheticsScore: 0.5,
        isUtility: false,
        faceQualityScore: nil,
        exposureBias: 0,
        sharpnessScore: nil,
        compositionOffsetScore: nil
    )

    // 診断結果はバックグラウンドのTaskからMainActorへ戻って反映されるため、条件成立をポーリングで待つ
    private func wait(until condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private struct StubQualityImageProvider: AILabelingImageProviding {
    let providesImage: Bool

    func thumbnail(for _: AILabelingTarget) async -> NSImage? {
        providesImage ? NSImage(size: NSSize(width: 1, height: 1)) : nil
    }
}

private struct StubQualityDiagnoser: PhotoQualityDiagnosing {
    let result: PhotoQualityDiagnosis?

    func diagnose(_: NSImage) -> PhotoQualityDiagnosis? {
        result
    }
}

private struct StubLabelingClassifier: AILabelingClassifying {
    func classify(_: NSImage) -> VisionLabelClassification? {
        VisionLabelClassification(categories: [.person], rawIdentifiers: ["test"])
    }
}
