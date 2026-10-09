import Foundation
import Testing

@testable import ShootLog

@MainActor
struct EXIFPanelViewModelTests {

    @Test func dimensionsTextFormatsWidthAndHeight() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.pixelWidth = 6000
        photo.pixelHeight = 4000
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.dimensionsText == "6000 x 4000")
    }

    @Test func dimensionsTextIsNilWhenMissing() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.dimensionsText == nil)
    }

    @Test func fileSizeTextIsNilWhenMissing() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.fileSizeText == nil)
    }

    @Test func fileSizeTextFormatsNonZeroByteCount() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.fileSizeBytes = 25_500_000
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        // ByteCountFormatter の正確な文字列はロケール依存のため、非空であることのみ検証する
        #expect(viewModel.fileSizeText?.isEmpty == false)
    }

    @Test func aiCategoriesReturnsMappedCategoriesFromRawValues() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.aiCategoryRawValues = ["person", "animal"]
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.aiCategories == [.person, .animal])
    }

    @Test func aiCategoriesIsEmptyWhenRawValuesEmpty() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.aiCategories.isEmpty)
    }

    @Test func aiCategoriesIgnoresUnknownRawValues() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.aiCategoryRawValues = ["person", "not-a-real-category"]
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.aiCategories == [.person])
    }

    @Test func qualityDiagnosisIsNilWhenOverallScoreMissing() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.qualityDiagnosisContent == nil)
    }

    @Test func qualityDiagnosisIsPresentWhenIsUtilityTrueButHasOtherInsights() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.aiDiagnosisFetchedAt = Date()
        photo.aiAestheticsOverallScore = 0.8
        photo.aiAestheticsIsUtility = true
        // darkExposureBias(-0.3)を下回るため改善指摘が1件出る
        photo.aiExposureBias = -0.5
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        let content = viewModel.qualityDiagnosisContent
        #expect(content != nil)
        #expect(content?.insights.contains(where: { $0.id == "ai.diagnosis.exposure.dark" }) == true)
        // isUtility=true の抑制対象は統合スコアの「良い点」だけ
        #expect(content?.insights.contains(where: { $0.id == "ai.diagnosis.overall.good" }) == false)
    }

    @Test func qualityDiagnosisIsNilWhenNotYetFetched() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.aiAestheticsOverallScore = 0.8
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.qualityDiagnosisContent == nil)
    }

    @Test func qualityDiagnosisIsNilWhenNoScoreAndNoInsight() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        // Vision失敗等で全スコアがnil＝指摘0件のときは空カードを出さない
        photo.aiDiagnosisFetchedAt = Date()
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.qualityDiagnosisContent == nil)
    }

    @Test func qualityDiagnosisIsPresentWhenIsUtilityFalse() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.aiDiagnosisFetchedAt = Date()
        photo.aiAestheticsOverallScore = 0.8
        photo.aiAestheticsIsUtility = false
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.qualityDiagnosisContent?.diagnosis.aestheticsScore == 0.8)
    }

    @Test func qualityDiagnosisTreatsMissingIsUtilityAsNotUtility() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.aiDiagnosisFetchedAt = Date()
        photo.aiAestheticsOverallScore = 0.5
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.qualityDiagnosisContent != nil)
        #expect(viewModel.qualityDiagnosisContent?.diagnosis.isUtility == false)
    }

    @Test func qualityDiagnosisCarriesAllScoreFields() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.aiDiagnosisFetchedAt = Date()
        photo.aiAestheticsOverallScore = 0.6
        photo.aiAestheticsIsUtility = false
        photo.aiFaceQualityScore = 0.9
        photo.aiExposureBias = -0.2
        photo.aiSharpnessScore = 0.4
        photo.aiCompositionOffsetScore = 0.7
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        let diagnosis = viewModel.qualityDiagnosisContent?.diagnosis
        #expect(diagnosis?.faceQualityScore == 0.9)
        #expect(diagnosis?.exposureBias == -0.2)
        #expect(diagnosis?.sharpnessScore == 0.4)
        #expect(diagnosis?.compositionOffsetScore == 0.7)
    }

    // MARK: - シャッタースピード

    @Test func shutterSpeedTextFormatsFractionAndSeconds() {
        #expect(EXIFPanelViewModel.shutterSpeedText(for: 1.0 / 250.0) == "1/250 s")
        #expect(EXIFPanelViewModel.shutterSpeedText(for: 2.0)?.hasSuffix(" s") == true)
    }

    @Test func shutterSpeedTextIsNilForInvalidValues() {
        #expect(EXIFPanelViewModel.shutterSpeedText(for: nil) == nil)
        #expect(EXIFPanelViewModel.shutterSpeedText(for: 0) == nil)
        #expect(EXIFPanelViewModel.shutterSpeedText(for: -0.01) == nil)
        #expect(EXIFPanelViewModel.shutterSpeedText(for: .nan) == nil)
        #expect(EXIFPanelViewModel.shutterSpeedText(for: .infinity) == nil)
        #expect(EXIFPanelViewModel.shutterSpeedText(for: .leastNonzeroMagnitude) == nil)
    }

    @Test func shutterSpeedTextPropertyDoesNotTrapOnZero() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.shutterSpeed = 0
        let viewModel = EXIFPanelViewModel(photo: photo)

        #expect(viewModel.shutterSpeedText == nil)
    }

    // MARK: - 撮影日時

    @Test func shootingDateTextIsNilBeforeEXIFFetched() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        let viewModel = EXIFPanelViewModel(photo: photo)

        #expect(viewModel.shootingDateText == nil)
    }

    @Test func shootingDateTextIsNilWhenEXIFHasModelButNoDate() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.cameraModel = "Camera"
        photo.exifFetchedAt = Date()
        photo.shootingDateFromMetadata = false
        let viewModel = EXIFPanelViewModel(photo: photo)

        #expect(viewModel.shootingDateText == nil)
    }

    @Test func shootingDateTextIsShownWhenDateCameFromEXIFWithoutModel() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.shootingDate = Date(timeIntervalSince1970: 1_600_000_000)
        photo.exifFetchedAt = Date()
        photo.shootingDateFromMetadata = true
        let viewModel = EXIFPanelViewModel(photo: photo)

        #expect(viewModel.shootingDateText != nil)
    }

    @Test func shootingDateTextFallsBackToFetchedFlagForLegacyRecords() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.exifFetchedAt = Date()
        let viewModel = EXIFPanelViewModel(photo: photo)

        #expect(viewModel.shootingDateText != nil)
    }
}

// EXIFService の純粋関数部分（ISO解決・Sigma判定）のテスト。
// pbxproj への新規ファイル追加を避けるため、EXIF表示系テストと同じファイルに置く
struct EXIFServiceParsingTests {

    @Test func resolveISOUsesSpeedRatingsWhenNotSaturated() {
        #expect(EXIFService.resolveISO(speedRatings: 3200, recommendedExposureIndex: 6400, isoSpeed: 6400) == 3200)
    }

    @Test func resolveISOPrefersRecommendedExposureIndexWhenSaturated() {
        #expect(EXIFService.resolveISO(speedRatings: 65535, recommendedExposureIndex: 102_400, isoSpeed: 204_800) == 102_400)
    }

    @Test func resolveISOFallsBackToISOSpeed() {
        #expect(EXIFService.resolveISO(speedRatings: 65535, recommendedExposureIndex: nil, isoSpeed: 204_800) == 204_800)
        #expect(EXIFService.resolveISO(speedRatings: nil, recommendedExposureIndex: nil, isoSpeed: 800) == 800)
    }

    @Test func resolveISOKeepsSaturatedValueWhenNoAlternative() {
        #expect(EXIFService.resolveISO(speedRatings: 65535, recommendedExposureIndex: nil, isoSpeed: nil) == 65535)
        #expect(EXIFService.resolveISO(speedRatings: nil, recommendedExposureIndex: nil, isoSpeed: nil) == nil)
    }

    @Test func isSigmaMatchesTrimmedCaseInsensitiveMake() {
        #expect(EXIFService.isSigma(make: "SIGMA"))
        #expect(EXIFService.isSigma(make: " Sigma \u{0}"))
        #expect(EXIFService.isSigma(make: "sigma "))
        #expect(!EXIFService.isSigma(make: "NIKON CORPORATION"))
        #expect(!EXIFService.isSigma(make: nil))
    }
}

// PhotoRepository のフォルダスキャン。pbxproj への新規ファイル追加を避けるためここに置く
struct PhotoRepositoryScanTests {

    @Test func scanSkipsDirectoriesWithImageExtension() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoRepositoryScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let photoURL = folder.appendingPathComponent("a.JPG")
        try Data([0xFF, 0xD8, 0xFF]).write(to: photoURL)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("x.jpg", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: folder.appendingPathComponent("notes.txt"))

        let result = try PhotoRepository.scanImageURLs(in: folder)

        #expect(result.urls.map(\.lastPathComponent) == ["a.JPG"])
    }
}
