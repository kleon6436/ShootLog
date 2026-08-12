import Foundation
import SwiftData

// 撮影設定分析画面のViewModel。絞り・SS・ISOの分布を計算する
@Observable
@MainActor
final class AnalysisViewModel {

    // raw valueは表示文言と分離した安定した識別子とし、表示名は displayName で持つ
    enum ChartTab: String, CaseIterable {
        case aperture
        case shutterSpeed
        case iso
    }

    // 画面のページ選択。チャート系列セレクタである ChartTab とは別軸で、
    // チャートを持たない「セッション」ページを含む
    enum AnalysisPage: String, CaseIterable {
        case aperture
        case shutterSpeed
        case iso
        case session

        // セグメントピッカーに表示するページ名
        var displayName: LocalizedStringResource {
            switch self {
            case .aperture:     "analysis.page.aperture"
            case .shutterSpeed: "analysis.page.shutterSpeed"
            case .iso:          "analysis.page.iso"
            case .session:      "analysis.page.session"
            }
        }

        // 対応するチャート系列。セッションページはチャートを持たないためnil
        var chartTab: ChartTab? {
            switch self {
            case .aperture:     .aperture
            case .shutterSpeed: .shutterSpeed
            case .iso:          .iso
            case .session:      nil
            }
        }
    }

    // チャートの系列。displayName はチャートの凡例と色スケールの双方で照合キーを兼ねるため、
    // 生の文字列ではなくこの型を経由して常に同じ値を使う
    enum ChartSeries: String, CaseIterable, Identifiable {
        case all
        case favorites

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all:       String(localized: "analysis.series.all")
            case .favorites: String(localized: "analysis.series.favorites")
            }
        }
    }

    struct DataPoint: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
        let sortKey: Double
        let series: ChartSeries
    }

    let photos: [Photo]
    var selectedPage: AnalysisPage = .aperture
    var selectedCamera: String? = nil       // nil = すべてのカメラ
    var showFavoritesOverlay: Bool = false

    var totalCount: Int { photos.count }

    // EXIF取得済み（絞り・SS・ISO のいずれかがある）写真の枚数
    var exifCount: Int {
        photos.filter { $0.aperture != nil || $0.shutterSpeed != nil || $0.iso != nil }.count
    }

    // EXIFから取得できたカメラモデルの重複なし一覧（ソート済み）
    var availableCameras: [String] {
        Array(Set(photos.compactMap(\.cameraModel))).sorted()
    }

    // カメラフィルター適用後の写真
    var filteredPhotos: [Photo] {
        guard let camera = selectedCamera else { return photos }
        return photos.filter { $0.cameraModel == camera }
    }

    // カメラフィルター適用後のお気に入り写真
    var favoriteFilteredPhotos: [Photo] {
        filteredPhotos.filter(\.isFavorite)
    }

    // タブと選択状態に応じたチャートデータ（オーバーレイ時は2系列）
    var currentData: [DataPoint] {
        guard let tab = selectedPage.chartTab else { return [] }
        let base = filteredPhotos
        let fav: [Photo]? = showFavoritesOverlay ? favoriteFilteredPhotos : nil
        switch tab {
        case .aperture:     return computeAperture(base: base, overlay: fav)
        case .shutterSpeed: return computeShutterSpeed(base: base, overlay: fav)
        case .iso:          return computeISO(base: base, overlay: fav)
        }
    }

    init(photos: [Photo]) {
        self.photos = photos
    }

    // MARK: - 絞り（全段バケット）

    static let fullStopApertures: [Double] = [
        1.0, 1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11.0, 16.0, 22.0, 32.0
    ]

    // 絞り値の数値部分のみ（範囲表記で "f/" を重複させないため分離）
    static func apertureValueText(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : "\(value)"
    }

    static func apertureLabel(_ value: Double) -> String {
        "f/" + apertureValueText(value)
    }

    private func computeAperture(base: [Photo], overlay: [Photo]?) -> [DataPoint] {
        let basePoints = bucketizeDouble(
            values: base.compactMap(\.aperture),
            candidates: Self.fullStopApertures,
            label: Self.apertureLabel,
            series: .all
        )
        guard let overlay else { return basePoints }
        let overlayPoints = bucketizeDouble(
            values: overlay.compactMap(\.aperture),
            candidates: Self.fullStopApertures,
            label: Self.apertureLabel,
            series: .favorites
        )
        return mergePoints(base: basePoints, overlay: overlayPoints)
    }

    // MARK: - シャッタースピード（全段バケット）

    static let fullStopShutterSpeeds: [Double] = [
        1.0/8000, 1.0/4000, 1.0/2000, 1.0/1000, 1.0/500,
        1.0/250,  1.0/125,  1.0/60,   1.0/30,   1.0/15,
        1.0/8,    1.0/4,    1.0/2,    1.0,       2.0, 4.0, 8.0, 15.0, 30.0
    ]

    static func ssLabel(_ seconds: Double) -> String {
        seconds >= 1.0 ? "\(Int(seconds.rounded()))s" : "1/\(Int((1.0/seconds).rounded()))"
    }

    private func computeShutterSpeed(base: [Photo], overlay: [Photo]?) -> [DataPoint] {
        let basePoints = bucketizeDouble(
            values: base.compactMap(\.shutterSpeed),
            candidates: Self.fullStopShutterSpeeds,
            label: Self.ssLabel,
            series: .all
        )
        guard let overlay else { return basePoints }
        let overlayPoints = bucketizeDouble(
            values: overlay.compactMap(\.shutterSpeed),
            candidates: Self.fullStopShutterSpeeds,
            label: Self.ssLabel,
            series: .favorites
        )
        return mergePoints(base: basePoints, overlay: overlayPoints)
    }

    // MARK: - ISO（標準2段階バケット）

    static let standardISOs: [Int] = [
        50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200, 102400
    ]

    static func isoLabel(_ value: Int) -> String {
        "ISO \(value)"
    }

    private func computeISO(base: [Photo], overlay: [Photo]?) -> [DataPoint] {
        let basePoints = bucketizeInt(
            values: base.compactMap(\.iso),
            candidates: Self.standardISOs,
            label: Self.isoLabel,
            series: .all
        )
        guard let overlay else { return basePoints }
        let overlayPoints = bucketizeInt(
            values: overlay.compactMap(\.iso),
            candidates: Self.standardISOs,
            label: Self.isoLabel,
            series: .favorites
        )
        return mergePoints(base: basePoints, overlay: overlayPoints)
    }

    // MARK: - ユーティリティ

    // 戻り値は常に sortKey 昇順。最頻バケットのタイ処理がこの順序に依存する
    func bucketizeDouble(
        values: [Double],
        candidates: [Double],
        label: (Double) -> String,
        series: ChartSeries
    ) -> [DataPoint] {
        guard !values.isEmpty else { return [] }
        var counts: [Double: Int] = [:]
        for v in values {
            let snapped = Self.snapLog(v, candidates)
            counts[snapped, default: 0] += 1
        }
        return counts.map { key, count in
            DataPoint(label: label(key), count: count, sortKey: key, series: series)
        }.sorted { $0.sortKey < $1.sortKey }
    }

    // 戻り値は常に sortKey 昇順。最頻バケットのタイ処理がこの順序に依存する
    func bucketizeInt(
        values: [Int],
        candidates: [Int],
        label: (Int) -> String,
        series: ChartSeries
    ) -> [DataPoint] {
        guard !values.isEmpty else { return [] }
        var counts: [Int: Int] = [:]
        for v in values {
            let snapped = Self.snapNearest(v, to: candidates)
            counts[snapped, default: 0] += 1
        }
        return counts.map { key, count in
            DataPoint(label: label(key), count: count, sortKey: Double(key), series: series)
        }.sorted { $0.sortKey < $1.sortKey }
    }

    // 両系列のデータポイントを sortKey 順でインターリーブ（x軸の表示順を統一する）
    private func mergePoints(base: [DataPoint], overlay: [DataPoint]) -> [DataPoint] {
        let allKeys = Set(base.map(\.sortKey)).union(overlay.map(\.sortKey)).sorted()
        let baseMap    = Dictionary(base.map    { ($0.sortKey, $0) }, uniquingKeysWith: { a, _ in a })
        let overlayMap = Dictionary(overlay.map { ($0.sortKey, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [DataPoint] = []
        for key in allKeys {
            if let b = baseMap[key]    { result.append(b) }
            if let o = overlayMap[key] { result.append(o) }
        }
        return result
    }

    // ログスケール最近傍スナップ（絞り・SSは対数スケール）
    static func snapLog(_ value: Double, _ candidates: [Double]) -> Double {
        guard !candidates.isEmpty, value > 0 else { return candidates.first ?? value }
        let logVal = log(value)
        return candidates.min(by: { abs(log($0) - logVal) < abs(log($1) - logVal) }) ?? value
    }

    // 線形最近傍スナップ（ISO）
    static func snapNearest(_ value: Int, to candidates: [Int]) -> Int {
        guard !candidates.isEmpty else { return value }
        return candidates.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}
