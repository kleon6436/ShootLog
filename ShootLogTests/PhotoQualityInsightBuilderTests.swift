import Testing

@testable import ShootLog

struct PhotoQualityInsightBuilderTests {

    // MARK: - exposureBias

    @Test func exposureBiasJustInsideGoodRangeProducesGoodInsight() {
        let diagnosis = makeDiagnosis(exposureBias: 0.15)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.contains { $0.id == "ai.diagnosis.exposure.good" })
    }

    @Test func exposureBiasJustOutsideGoodRangeProducesNoGoodInsight() {
        let diagnosis = makeDiagnosis(exposureBias: 0.16)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.exposure.good" })
    }

    @Test func exposureBiasJustAboveDarkThresholdProducesNoDarkInsight() {
        let diagnosis = makeDiagnosis(exposureBias: -0.3)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.exposure.dark" })
    }

    @Test func exposureBiasBelowDarkThresholdProducesDarkInsight() {
        let diagnosis = makeDiagnosis(exposureBias: -0.31)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.contains { $0.id == "ai.diagnosis.exposure.dark" })
    }

    @Test func exposureBiasJustBelowBrightThresholdProducesNoBrightInsight() {
        let diagnosis = makeDiagnosis(exposureBias: 0.3)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.exposure.bright" })
    }

    @Test func exposureBiasAboveBrightThresholdProducesBrightInsight() {
        let diagnosis = makeDiagnosis(exposureBias: 0.31)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.contains { $0.id == "ai.diagnosis.exposure.bright" })
    }

    @Test func exposureBiasMissingProducesNoExposureInsight() {
        let diagnosis = makeDiagnosis(exposureBias: nil)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id.hasPrefix("ai.diagnosis.exposure") })
    }

    // MARK: - sharpnessScore

    @Test func sharpnessScoreJustAboveGoodThresholdProducesGoodInsight() {
        let diagnosis = makeDiagnosis(sharpnessScore: 0.71)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.contains { $0.id == "ai.diagnosis.sharpness.good" })
    }

    @Test func sharpnessScoreAtGoodThresholdProducesNoGoodInsight() {
        let diagnosis = makeDiagnosis(sharpnessScore: 0.7)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.sharpness.good" })
    }

    @Test func sharpnessScoreAtSoftThresholdProducesNoSoftInsight() {
        let diagnosis = makeDiagnosis(sharpnessScore: 0.35)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.sharpness.soft" })
    }

    @Test func sharpnessScoreJustBelowSoftThresholdProducesSoftInsight() {
        let diagnosis = makeDiagnosis(sharpnessScore: 0.34)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.contains { $0.id == "ai.diagnosis.sharpness.soft" })
    }

    @Test func sharpnessScoreBetweenThresholdsProducesNoSharpnessInsight() {
        let diagnosis = makeDiagnosis(sharpnessScore: 0.5)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id.hasPrefix("ai.diagnosis.sharpness") })
    }

    // MARK: - compositionOffsetScore

    @Test func compositionOffsetAtThresholdProducesNoInsight() {
        let diagnosis = makeDiagnosis(compositionOffsetScore: 0.6)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.composition.offCenter" })
    }

    @Test func compositionOffsetJustAboveThresholdProducesInsight() {
        let diagnosis = makeDiagnosis(compositionOffsetScore: 0.61)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.contains { $0.id == "ai.diagnosis.composition.offCenter" })
    }

    // MARK: - faceQualityScore

    @Test func faceQualityAtLowThresholdProducesNoLowInsight() {
        let diagnosis = makeDiagnosis(faceQualityScore: 0.4)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.face.low" })
    }

    @Test func faceQualityJustBelowLowThresholdProducesLowInsight() {
        let diagnosis = makeDiagnosis(faceQualityScore: 0.39)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.contains { $0.id == "ai.diagnosis.face.low" })
    }

    @Test func faceQualityAtGoodThresholdProducesNoGoodInsight() {
        let diagnosis = makeDiagnosis(faceQualityScore: 0.75)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.face.good" })
    }

    @Test func faceQualityJustAboveGoodThresholdProducesGoodInsight() {
        let diagnosis = makeDiagnosis(faceQualityScore: 0.76)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.contains { $0.id == "ai.diagnosis.face.good" })
    }

    @Test func faceQualityMissingProducesNoFaceInsight() {
        let diagnosis = makeDiagnosis(faceQualityScore: nil)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id.hasPrefix("ai.diagnosis.face") })
    }

    // MARK: - aestheticsScore / isUtility

    @Test func aestheticsScoreAboveThresholdAndNotUtilityProducesOverallGoodInsight() {
        let diagnosis = makeDiagnosis(aestheticsScore: 0.71, isUtility: false)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.contains { $0.id == "ai.diagnosis.overall.good" })
    }

    @Test func aestheticsScoreAtThresholdProducesNoOverallGoodInsight() {
        let diagnosis = makeDiagnosis(aestheticsScore: 0.7, isUtility: false)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.overall.good" })
    }

    @Test func aestheticsScoreAboveThresholdButUtilityProducesNoOverallGoodInsight() {
        let diagnosis = makeDiagnosis(aestheticsScore: 0.9, isUtility: true)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(!insights.contains { $0.id == "ai.diagnosis.overall.good" })
    }

    // MARK: - Missing face score

    @Test func noFaceQualityScoreProducesNoFaceRelatedInsights() {
        let diagnosis = makeDiagnosis(faceQualityScore: nil)
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)

        #expect(insights.allSatisfy { !$0.id.hasPrefix("ai.diagnosis.face") })
    }

    // MARK: - Maximum count per kind

    @Test func positiveInsightsAreCappedAtMaximumCount() {
        let diagnosis = PhotoQualityDiagnosis(
            aestheticsScore: 0.9,
            isUtility: false,
            faceQualityScore: 0.9,
            exposureBias: 0.0,
            sharpnessScore: 0.9,
            compositionOffsetScore: 0.0
        )
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)
        let positiveCount = insights.filter { $0.kind == .positive }.count

        #expect(positiveCount == PhotoQualityInsightBuilder.maximumInsightCount)
    }

    @Test func improvementInsightsAreCappedAtMaximumCount() {
        // exposureBias が暗/明どちらかにしか倒れないため、改善系は exposure + sharpness +
        // composition + face の4条件のうち exposure は1件のみ成立させ、最大3件になることを確認する
        let diagnosis = PhotoQualityDiagnosis(
            aestheticsScore: nil,
            isUtility: false,
            faceQualityScore: 0.1,
            exposureBias: -0.5,
            sharpnessScore: 0.1,
            compositionOffsetScore: 0.9
        )
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)
        let improvementCount = insights.filter { $0.kind == .improvement }.count

        // 実装は改善系4条件のうち最大 maximumInsightCount 件までしか切り詰めない
        // （exposure/sharpness/composition/faceの4条件全てが成立し得るため、上限確認は
        // 「上限を超えない」ことを検証する）
        #expect(improvementCount <= PhotoQualityInsightBuilder.maximumInsightCount)
        #expect(improvementCount == 3)
    }

    // MARK: - Helpers

    private func makeDiagnosis(
        aestheticsScore: Double? = nil,
        isUtility: Bool = false,
        faceQualityScore: Double? = nil,
        exposureBias: Double? = nil,
        sharpnessScore: Double? = nil,
        compositionOffsetScore: Double? = nil
    ) -> PhotoQualityDiagnosis {
        PhotoQualityDiagnosis(
            aestheticsScore: aestheticsScore,
            isUtility: isUtility,
            faceQualityScore: faceQualityScore,
            exposureBias: exposureBias,
            sharpnessScore: sharpnessScore,
            compositionOffsetScore: compositionOffsetScore
        )
    }
}
