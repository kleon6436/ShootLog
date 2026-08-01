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
            filterBar
            Divider()
            chartArea
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
        Picker("グラフ種別", selection: $vm.selectedTab) {
            ForEach(AnalysisViewModel.ChartTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
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

    // MARK: - チャートエリア

    @ViewBuilder
    private var chartArea: some View {
        let data = vm.currentData
        if data.isEmpty {
            emptyState
        } else {
            barChart(data: data)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
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
