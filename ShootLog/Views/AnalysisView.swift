import SwiftUI
import Charts

// 撮影設定の傾向グラフ。絞り・SS・ISO の分布を棒グラフで表示する
// Phase 9: カメラ別フィルターとお気に入りvs全体のオーバーレイ比較に対応
struct AnalysisView: View {
    @State private var vm: AnalysisViewModel
    @Environment(\.dismiss) private var dismiss

    init(photos: [Photo]) {
        _vm = State(initialValue: AnalysisViewModel(photos: photos))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabPicker
            // カメラ絞り込みを適用するとお気に入り比率の意味が変わるため、セッションページでは隠す
            if vm.selectedPage != .session {
                filterBar
            }
            Divider()
            contentArea
        }
        .frame(width: 680, height: 560)
        // チャートの判読性を保つため不透明な背景を維持。AppKitブリッジではなくSwiftUIネイティブのセマンティックスタイルを使用
        .background(.background)
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("analysis.title")
                    .font(.title2.bold())
                Text("analysis.exifProgress \(vm.exifCount) \(vm.totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("common.close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - タブ

    private var tabPicker: some View {
        Picker("analysis.chartType", selection: $vm.selectedPage) {
            ForEach(AnalysisViewModel.AnalysisPage.allCases, id: \.self) { page in
                Text(page.displayName).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - フィルターバー（カメラ別・お気に入り比較）

    private var filterBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "camera")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Picker("analysis.camera", selection: $vm.selectedCamera) {
                    Text("analysis.camera.all").tag(Optional<String>.none)
                    if !vm.availableCameras.isEmpty {
                        Divider()
                        ForEach(vm.availableCameras, id: \.self) { camera in
                            Text(camera).tag(Optional(camera))
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220)
                .accessibilityLabel("a11y.analysis.cameraFilter")
            }

            Spacer()

            // フィルター適用中の枚数バッジ
            if vm.selectedCamera != nil || vm.showFavoritesOverlay {
                Text(filterSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $vm.showFavoritesOverlay) {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(vm.showFavoritesOverlay ? Color.orange : Color.secondary)
                    Text("analysis.compareFavorites")
                }
                .font(.caption)
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("a11y.analysis.compareFavorites")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var filterSummary: String {
        let total = vm.filteredPhotos.count
        let fav   = vm.favoriteFilteredPhotos.count
        if vm.showFavoritesOverlay {
            return String(localized: "analysis.filterSummary.withFavorites \(total) \(fav)")
        }
        return String(localized: "analysis.filterSummary \(total)")
    }

    // MARK: - コンテンツ切替

    @ViewBuilder
    private var contentArea: some View {
        if vm.selectedPage == .session {
            sessionArea
        } else {
            chartArea
        }
    }

    // MARK: - チャートエリア

    @ViewBuilder
    private var chartArea: some View {
        let data = vm.currentData
        VStack(spacing: 0) {
            insightRow
            if data.isEmpty {
                emptyState
            } else {
                barChart(data: data)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
    }

    // 選択中タブの指標について、お気に入りの傾向を1行で示す
    private var insightRow: some View {
        let insight = vm.currentInsightText
        let text = insight ?? String(localized: "analysis.insight.insufficient")
        return HStack(spacing: Spacing.small) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(insight == nil ? .caption : .callout)
                .foregroundStyle(insight == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, Spacing.large)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("a11y.analysis.insight \(text)"))
    }

    private func barChart(data: [AnalysisViewModel.DataPoint]) -> some View {
        let isOverlay = vm.showFavoritesOverlay
        let maxCount  = data.map(\.count).max() ?? 1
        let yMax      = maxCount + max(2, Int(Double(maxCount) * 0.2))

        return Chart(data) { dp in
            BarMark(
                x: .value("analysis.chart.label", dp.label),
                y: .value("analysis.chart.count", dp.count)
            )
            .foregroundStyle(by: .value("analysis.chart.series", dp.series.displayName))
            .position(by: .value("analysis.chart.series", dp.series.displayName), axis: .horizontal)
            .cornerRadius(CornerRadius.small)
            .annotation(position: .top, alignment: .center, spacing: 2) {
                // オーバーレイ時はバーが狭くなるためカウントラベルを非表示
                if !isOverlay {
                    Text(dp.count.formatted(.number.grouping(.never)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // 系列識別用のデータ可視化カラー。UIクロームではなくチャートのデータ系列を区別する意図的な固定色のため変更しない
        .chartForegroundStyleScale([
            AnalysisViewModel.ChartSeries.all.displayName: Color.accentColor,
            AnalysisViewModel.ChartSeries.favorites.displayName: Color.orange
        ])
        .chartLegend(isOverlay ? .visible : .hidden)
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(v.formatted(.number.grouping(.never))).font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisTick()
                AxisValueLabel(orientation: .verticalReversed)
                    .font(.caption2)
            }
        }
        .frame(height: 320)
    }

    // MARK: - セッションエリア

    // 固定680×560のシートに4セクションを収めるためスクロールさせる
    private var sessionArea: some View {
        let favoritesCount = vm.sessionFavorites.count
        let isFavoritesEmpty = favoritesCount == 0
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xLarge * 2) {
                favoriteRatioSection(favoritesCount: favoritesCount)
                exifRepresentativeSection(favoritesCount: favoritesCount, isFavoritesEmpty: isFavoritesEmpty)
                tagAggregationSection
                recipeSection(favoritesCount: favoritesCount, isFavoritesEmpty: isFavoritesEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private func favoriteRatioSection(favoritesCount: Int) -> some View {
        sessionSection(title: String(localized: "analysis.session.favoriteRatio.title \(vm.totalCount)")) {
            if let ratio = vm.favoriteRatio {
                let percent = Int((ratio * 100).rounded())
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(String(localized: "analysis.session.favoriteRatio.value \(favoritesCount) \(vm.totalCount) \(percent)"))
                        .font(.title3.bold())
                    ProgressView(value: ratio)
                        .progressViewStyle(.linear)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("a11y.analysis.favoriteRatio \(vm.totalCount) \(favoritesCount) \(percent)"))
            } else {
                sessionPlaceholder(String(localized: "analysis.session.noPhotos"))
            }
        }
    }

    private func exifRepresentativeSection(favoritesCount: Int, isFavoritesEmpty: Bool) -> some View {
        sessionSection(title: String(localized: "analysis.session.exifRepresentative.title \(favoritesCount)")) {
            let metrics = vm.exifRepresentativeValues
            if isFavoritesEmpty {
                sessionPlaceholder(String(localized: "analysis.session.noFavorites"))
            } else if metrics.isEmpty {
                sessionPlaceholder(String(localized: "analysis.session.exifNotLoaded"))
            } else {
                metricRows(
                    metrics,
                    accessibilityPrefix: String(localized: "analysis.session.exifRepresentative.prefix")
                )
            }
        }
    }

    private var tagAggregationSection: some View {
        sessionSection(title: String(localized: "analysis.session.tagAggregation.title \(vm.totalCount)")) {
            let counts = vm.tagAggregation
            if counts.isEmpty {
                sessionPlaceholder(String(localized: "analysis.session.noTaggedPhotos"))
            } else {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(counts) { item in
                        HStack {
                            Text(item.category.displayName)
                                .font(.callout)
                            Spacer(minLength: Spacing.xLarge)
                            Text(String(localized: "analysis.photoCount \(item.count)"))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("a11y.analysis.tagCount \(item.category.displayName) \(item.count)"))
                    }
                }
            }
        }
    }

    private func recipeSection(favoritesCount: Int, isFavoritesEmpty: Bool) -> some View {
        sessionSection(title: String(localized: "analysis.session.recipe.title \(favoritesCount)")) {
            let metrics = vm.recipeRange
            if isFavoritesEmpty {
                sessionPlaceholder(String(localized: "analysis.session.noFavorites"))
            } else if metrics.isEmpty {
                sessionPlaceholder(String(localized: "analysis.session.exifNotLoaded"))
            } else {
                metricRows(metrics, accessibilityPrefix: String(localized: "analysis.session.recipe.prefix"))
            }
        }
    }

    private func metricRows(
        _ metrics: [AnalysisViewModel.SessionMetric],
        accessibilityPrefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(metrics) { metric in
                HStack {
                    Text(metric.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.xLarge)
                    Text(metric.text)
                        .font(.callout.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    Text("a11y.analysis.metricRow \(accessibilityPrefix) \(metric.name) \(metric.text)")
                )
            }
        }
    }

    private func sessionSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Text(title)
                .font(.headline)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.xLarge)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
        }
    }

    private func sessionPlaceholder(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - 空状態

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("analysis.empty.title")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("analysis.empty.subtitle")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}
