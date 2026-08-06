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
                Text("撮影設定の傾向")
                    .font(.title2.bold())
                Text("EXIF取得済み \(vm.exifCount) / \(vm.totalCount) 枚")
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
            .accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - タブ

    private var tabPicker: some View {
        Picker("グラフ種別", selection: $vm.selectedPage) {
            ForEach(AnalysisViewModel.AnalysisPage.allCases, id: \.self) { page in
                Text(page.rawValue).tag(page)
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
                Picker("カメラ", selection: $vm.selectedCamera) {
                    Text("すべてのカメラ").tag(Optional<String>.none)
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
                .accessibilityLabel("カメラフィルター")
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
                    Text("お気に入りと比較")
                }
                .font(.caption)
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("お気に入りとの比較を表示")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var filterSummary: String {
        let total = vm.filteredPhotos.count
        let fav   = vm.favoriteFilteredPhotos.count
        if vm.showFavoritesOverlay {
            return "全体 \(total) 枚 / お気に入り \(fav) 枚"
        }
        return "\(total) 枚"
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
        let text = insight ?? "お気に入りが少ないため参考情報なし"
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
        .accessibilityLabel("お気に入り傾向: \(text)")
    }

    private func barChart(data: [AnalysisViewModel.DataPoint]) -> some View {
        let isOverlay = vm.showFavoritesOverlay
        let maxCount  = data.map(\.count).max() ?? 1
        let yMax      = maxCount + max(2, Int(Double(maxCount) * 0.2))

        return Chart(data) { dp in
            BarMark(
                x: .value("ラベル", dp.label),
                y: .value("枚数", dp.count)
            )
            .foregroundStyle(by: .value("系列", dp.series))
            .position(by: .value("系列", dp.series), axis: .horizontal)
            .cornerRadius(CornerRadius.small)
            .annotation(position: .top, alignment: .center, spacing: 2) {
                // オーバーレイ時はバーが狭くなるためカウントラベルを非表示
                if !isOverlay {
                    Text("\(dp.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // 系列識別用のデータ可視化カラー。UIクロームではなくチャートのデータ系列を区別する意図的な固定色のため変更しない
        .chartForegroundStyleScale([
            "全体": Color.accentColor,
            "お気に入り": Color.orange
        ])
        .chartLegend(isOverlay ? .visible : .hidden)
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)").font(.caption2)
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
        sessionSection(title: "お気に入り比率(フォルダ全体 \(vm.totalCount)枚)") {
            if let ratio = vm.favoriteRatio {
                let percent = Int((ratio * 100).rounded())
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("\(favoritesCount) / \(vm.totalCount) 枚(\(percent)%)")
                        .font(.title3.bold())
                    ProgressView(value: ratio)
                        .progressViewStyle(.linear)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("お気に入り比率 フォルダ全体\(vm.totalCount)枚中\(favoritesCount)枚、\(percent)パーセント")
            } else {
                sessionPlaceholder("写真がありません")
            }
        }
    }

    private func exifRepresentativeSection(favoritesCount: Int, isFavoritesEmpty: Bool) -> some View {
        sessionSection(title: "EXIF代表値(お気に入り \(favoritesCount)枚、値ありのみ、フォルダ全体基準)") {
            let metrics = vm.exifRepresentativeValues
            if isFavoritesEmpty {
                sessionPlaceholder("お気に入りがありません")
            } else if metrics.isEmpty {
                sessionPlaceholder("EXIFが未取得です。写真を選択すると読み込まれます")
            } else {
                metricRows(metrics, accessibilityPrefix: "EXIF代表値")
            }
        }
    }

    private var tagAggregationSection: some View {
        sessionSection(title: "タグ集計(フォルダ全体 \(vm.totalCount)枚)") {
            let counts = vm.tagAggregation
            if counts.isEmpty {
                sessionPlaceholder("タグ付与写真なし")
            } else {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(counts) { item in
                        HStack {
                            Text(item.category.displayName)
                                .font(.callout)
                            Spacer(minLength: Spacing.xLarge)
                            Text("\(item.count)枚")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("タグ集計 \(item.category.displayName) \(item.count)枚")
                    }
                }
            }
        }
    }

    private func recipeSection(favoritesCount: Int, isFavoritesEmpty: Bool) -> some View {
        sessionSection(title: "設定レシピ(お気に入り \(favoritesCount)枚、値ありのみ、フォルダ全体基準)") {
            let metrics = vm.recipeRange
            if isFavoritesEmpty {
                sessionPlaceholder("お気に入りがありません")
            } else if metrics.isEmpty {
                sessionPlaceholder("EXIFが未取得です。写真を選択すると読み込まれます")
            } else {
                metricRows(metrics, accessibilityPrefix: "設定レシピ")
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
                .accessibilityLabel("\(accessibilityPrefix) \(metric.name) \(metric.text)")
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
            Text("EXIFデータがありません")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("写真を選択してEXIFを読み込むか、別のタブを選択してください")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}
