import Foundation

/// 画質診断から導いた1件の指摘。
struct PhotoQualityInsight: Identifiable, Sendable {
    enum Kind: Sendable {
        case positive
        case improvement
    }

    let id: String
    let kind: Kind
    let messageKey: LocalizedStringResource
}

/// 診断スコアを定型の指摘文へ変換する閾値テーブル。
/// しきい値は実写真データでの検証前の暫定値で、指摘の偏りを見ながら調整する。
enum PhotoQualityInsightBuilder {
    /// 良い点・改善ポイントそれぞれの表示上限
    static let maximumInsightCount = 3

    static func buildInsights(from diagnosis: PhotoQualityDiagnosis) -> [PhotoQualityInsight] {
        Array(positiveInsights(from: diagnosis).prefix(maximumInsightCount))
            + improvementInsights(from: diagnosis).prefix(maximumInsightCount)
    }

    // MARK: - Private

    private static func positiveInsights(from diagnosis: PhotoQualityDiagnosis) -> [PhotoQualityInsight] {
        var insights: [PhotoQualityInsight] = []

        if let exposureBias = diagnosis.exposureBias, abs(exposureBias) <= goodExposureBias {
            insights.append(
                PhotoQualityInsight(
                    id: "ai.diagnosis.exposure.good",
                    kind: .positive,
                    messageKey: "ai.diagnosis.exposure.good"
                )
            )
        }
        if let sharpnessScore = diagnosis.sharpnessScore, sharpnessScore > goodSharpness {
            insights.append(
                PhotoQualityInsight(
                    id: "ai.diagnosis.sharpness.good",
                    kind: .positive,
                    messageKey: "ai.diagnosis.sharpness.good"
                )
            )
        }
        if let faceQualityScore = diagnosis.faceQualityScore, faceQualityScore > goodFaceQuality {
            insights.append(
                PhotoQualityInsight(
                    id: "ai.diagnosis.face.good",
                    kind: .positive,
                    messageKey: "ai.diagnosis.face.good"
                )
            )
        }
        if let aestheticsScore = diagnosis.aestheticsScore,
           aestheticsScore > goodAestheticsScore,
           !diagnosis.isUtility {
            insights.append(
                PhotoQualityInsight(
                    id: "ai.diagnosis.overall.good",
                    kind: .positive,
                    messageKey: "ai.diagnosis.overall.good"
                )
            )
        }

        return insights
    }

    private static func improvementInsights(from diagnosis: PhotoQualityDiagnosis) -> [PhotoQualityInsight] {
        var insights: [PhotoQualityInsight] = []

        if let exposureBias = diagnosis.exposureBias {
            if exposureBias < darkExposureBias {
                insights.append(
                    PhotoQualityInsight(
                        id: "ai.diagnosis.exposure.dark",
                        kind: .improvement,
                        messageKey: "ai.diagnosis.exposure.dark"
                    )
                )
            } else if exposureBias > brightExposureBias {
                insights.append(
                    PhotoQualityInsight(
                        id: "ai.diagnosis.exposure.bright",
                        kind: .improvement,
                        messageKey: "ai.diagnosis.exposure.bright"
                    )
                )
            }
        }
        if let sharpnessScore = diagnosis.sharpnessScore, sharpnessScore < softSharpness {
            insights.append(
                PhotoQualityInsight(
                    id: "ai.diagnosis.sharpness.soft",
                    kind: .improvement,
                    messageKey: "ai.diagnosis.sharpness.soft"
                )
            )
        }
        if let compositionOffsetScore = diagnosis.compositionOffsetScore,
           compositionOffsetScore > offCenterComposition {
            insights.append(
                PhotoQualityInsight(
                    id: "ai.diagnosis.composition.offCenter",
                    kind: .improvement,
                    messageKey: "ai.diagnosis.composition.offCenter"
                )
            )
        }
        if let faceQualityScore = diagnosis.faceQualityScore, faceQualityScore < lowFaceQuality {
            insights.append(
                PhotoQualityInsight(
                    id: "ai.diagnosis.face.low",
                    kind: .improvement,
                    messageKey: "ai.diagnosis.face.low"
                )
            )
        }

        return insights
    }

    // MARK: - Thresholds

    private static let goodExposureBias = 0.15
    private static let darkExposureBias = -0.3
    private static let brightExposureBias = 0.3
    private static let softSharpness = 0.35
    private static let goodSharpness = 0.7
    private static let offCenterComposition = 0.6
    private static let lowFaceQuality = 0.4
    private static let goodFaceQuality = 0.75
    private static let goodAestheticsScore = 0.7
}
