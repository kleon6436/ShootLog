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
}
