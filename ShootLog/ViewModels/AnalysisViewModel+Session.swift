import Foundation

// 「セッション」ページの集計。お気に入り比率・EXIF代表値・タグ集計・設定レシピを算出する。
// insight側と同じ理由（photos は let、EXIFはシート表示後に非同期で埋まる）で
// いずれも意図的にキャッシュしない computed var とする。
//
// 母集団はセクションごとに異なり、セッションページでは一切カメラ絞り込みを参照しない
// （Viewがセッションページでカメラ絞り込みUIを隠すため、絞り込みを見ると数値の意味が壊れる）:
//   favoriteRatio / tagAggregation           … フォルダ全体
//   exifRepresentativeValues / recipeRange   … フォルダ全体のお気に入り（sessionFavorites）
extension AnalysisViewModel {

    // 指標1件分の表示内容
    struct SessionMetric: Identifiable {
        let name: String
        let text: String
        var id: String { name }
    }

    // タグ1件分の集計結果
    struct TagCount: Identifiable {
        let category: SuccessTagCategory
        let count: Int
        var id: String { category.rawValue }
    }

    // カメラ絞り込みを無視した、フォルダ全体のお気に入り
    var sessionFavorites: [Photo] {
        photos.filter(\.isFavorite)
    }

    // フォルダ全体に対するお気に入りの比率（0...1）。写真ゼロ枚ならnil
    var favoriteRatio: Double? {
        guard totalCount > 0 else { return nil }
        return Double(sessionFavorites.count) / Double(totalCount)
    }

    // お気に入りのEXIF代表値（最頻スナップバケット）。値が1件も無い指標は含めない
    var exifRepresentativeValues: [SessionMetric] {
        let favorites = sessionFavorites
        var metrics: [SessionMetric] = []

        let apertures = favorites.compactMap(\.aperture)
        if let top = Self.modalPoint(in: bucketizeDouble(
            values: apertures,
            candidates: Self.fullStopApertures,
            label: Self.apertureLabel,
            series: "お気に入り"
        )) {
            metrics.append(SessionMetric(name: "絞り", text: top.label))
        }

        let shutterSpeeds = favorites.compactMap(\.shutterSpeed)
        if let top = Self.modalPoint(in: bucketizeDouble(
            values: shutterSpeeds,
            candidates: Self.fullStopShutterSpeeds,
            label: Self.ssLabel,
            series: "お気に入り"
        )) {
            metrics.append(SessionMetric(name: "SS", text: top.label))
        }

        let isos = favorites.compactMap(\.iso)
        if let top = Self.modalPoint(in: bucketizeInt(
            values: isos,
            candidates: Self.standardISOs,
            label: Self.isoLabel,
            series: "お気に入り"
        )) {
            metrics.append(SessionMetric(name: "ISO", text: top.label))
        }

        return metrics
    }

    // フォルダ全体の写真に付与された成功要因タグの集計。
    // 1件も付与が無ければ空配列（Viewが空状態を表示する）。
    // 表示順は SuccessTagCategory の宣言順に固定する
    var tagAggregation: [TagCount] {
        var counts: [SuccessTagCategory: Int] = [:]
        for photo in photos {
            for rawValue in photo.successTagRawValues {
                guard let tag = SuccessTagCategory(rawValue: rawValue) else { continue }
                counts[tag, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return [] }
        return SuccessTagCategory.allCases.map {
            TagCount(category: $0, count: counts[$0] ?? 0)
        }
    }

    // お気に入りの設定レシピ（スナップ済み最小〜最大）。値が1件も無い指標は含めない
    var recipeRange: [SessionMetric] {
        let favorites = sessionFavorites
        var metrics: [SessionMetric] = []

        let apertures = favorites.compactMap(\.aperture).map { Self.snapLog($0, Self.fullStopApertures) }
        if let low = apertures.min(), let high = apertures.max() {
            let text = low == high
                ? Self.apertureLabel(low)
                : "\(Self.apertureLabel(low))〜\(Self.apertureValueText(high))"
            metrics.append(SessionMetric(name: "絞り", text: text))
        }

        let shutterSpeeds = favorites.compactMap(\.shutterSpeed).map { Self.snapLog($0, Self.fullStopShutterSpeeds) }
        if let low = shutterSpeeds.min(), let high = shutterSpeeds.max() {
            let text = low == high
                ? Self.ssLabel(low)
                : "\(Self.ssLabel(low))〜\(Self.ssLabel(high))"
            metrics.append(SessionMetric(name: "SS", text: text))
        }

        let isos = favorites.compactMap(\.iso).map { Self.snapNearest($0, to: Self.standardISOs) }
        if let low = isos.min(), let high = isos.max() {
            let text = low == high
                ? Self.isoLabel(low)
                : "\(Self.isoLabel(low))〜\(high)"
            metrics.append(SessionMetric(name: "ISO", text: text))
        }

        return metrics
    }
}
