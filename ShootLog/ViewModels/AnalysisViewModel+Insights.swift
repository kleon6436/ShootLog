import Foundation

// 絞り・SS・ISO各タブに表示する、お気に入り傾向の1行insight文を生成する。
// AnalysisViewModel.photos は let で不変であり、EXIFはシート表示後に非同期で
// 埋まっていくため、ここでの計算は意図的にキャッシュせず computed var のままにする。
extension AnalysisViewModel {

    // insight文を出すために必要な最小サンプル数（当該指標のEXIF値ありのお気に入り枚数）
    static let insightMinimumSampleCount = 5

    // 絞りタブ用のinsight文。母集団はカメラ絞り込み後のお気に入りのうち絞り値ありのもの
    var apertureInsightText: String? {
        let values = favoriteFilteredPhotos.compactMap(\.aperture)
        guard values.count >= Self.insightMinimumSampleCount else { return nil }
        let points = bucketizeDouble(
            values: values,
            candidates: Self.fullStopApertures,
            label: Self.apertureLabel,
            series: "お気に入り"
        )
        return Self.insightText(points: points, total: values.count)
    }

    // SSタブ用のinsight文。母集団はカメラ絞り込み後のお気に入りのうちSS値ありのもの
    var shutterSpeedInsightText: String? {
        let values = favoriteFilteredPhotos.compactMap(\.shutterSpeed)
        guard values.count >= Self.insightMinimumSampleCount else { return nil }
        let points = bucketizeDouble(
            values: values,
            candidates: Self.fullStopShutterSpeeds,
            label: Self.ssLabel,
            series: "お気に入り"
        )
        return Self.insightText(points: points, total: values.count)
    }

    // ISOタブ用のinsight文。母集団はカメラ絞り込み後のお気に入りのうちISO値ありのもの
    var isoInsightText: String? {
        let values = favoriteFilteredPhotos.compactMap(\.iso)
        guard values.count >= Self.insightMinimumSampleCount else { return nil }
        let points = bucketizeInt(
            values: values,
            candidates: Self.standardISOs,
            label: Self.isoLabel,
            series: "お気に入り"
        )
        return Self.insightText(points: points, total: values.count)
    }

    // 選択中ページに対応するinsight文。セッションページではnil
    var currentInsightText: String? {
        switch selectedPage.chartTab {
        case .aperture:     apertureInsightText
        case .shutterSpeed: shutterSpeedInsightText
        case .iso:          isoInsightText
        case nil:           nil
        }
    }

    // MARK: - 共通ロジック

    static func insightText(points: [AnalysisViewModel.DataPoint], total: Int) -> String? {
        guard let top = modalPoint(in: points) else { return nil }
        return "お気に入りは \(top.label) 付近が最多(\(top.count)/\(total)枚)"
    }

    // 最頻バケットを返す。Dictionary.max(by:) はハッシュシード依存で非決定的なため使わず、
    // sortKey昇順の並びで先に現れた方を勝たせる（＝より開放的な絞り・より高速なSS・より低いISO）
    static func modalPoint(in points: [AnalysisViewModel.DataPoint]) -> AnalysisViewModel.DataPoint? {
        var best: AnalysisViewModel.DataPoint?
        for point in points where point.count > (best?.count ?? 0) {
            best = point
        }
        return best
    }
}
