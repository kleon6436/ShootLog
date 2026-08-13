import SwiftUI

// AI超解像書き出しのモーダルシート。設定 → 実行中 → 完了 の3段階を状態で切り替える
struct UpscaleExportSheet: View {
    @Bindable var contentViewModel: ContentViewModel
    @Bindable var viewModel: UpscaleExportViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.xLarge) {
            // AI生成物であることの開示は設定→実行中→完了を通じて常に見える位置に置く
            // (isTrainedAlgorithmicMediaがtrueになるのはaiSuperResolution選択時のみ。
            // 従来方式(Lanczos)は学習済みモデルではないため対象外)
            if viewModel.engineKind == .aiSuperResolution, !viewModel.state.isFailed {
                aiGeneratedNotice
            }

            switch viewModel.state {
            case .configuring:
                configuringView
            case .running, .cancelling:
                runningView
            case .finished(let url):
                finishedView(url: url)
            case .failed(let error):
                failedView(error: error)
            }
        }
        .padding(Spacing.xLarge)
        .frame(width: 420)
    }

    private var aiGeneratedNotice: some View {
        Label("upscale.aiGeneratedDetail.notice", systemImage: "sparkles")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - 設定

    private var configuringView: some View {
        VStack(alignment: .leading, spacing: Spacing.xLarge) {
            Text("upscale.configuring.title")
                .font(.headline)

            Form {
                Picker("upscale.scaleFactor", selection: $viewModel.scaleFactor) {
                    ForEach(viewModel.availableScaleFactors) { factor in
                        Text(factor.displayName).tag(factor)
                    }
                }
                .accessibilityLabel("upscale.scaleFactor")

                Picker("upscale.engine", selection: $viewModel.engineKind) {
                    ForEach(UpscaleExportViewModel.EngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .accessibilityLabel("upscale.engine")

                Picker("upscale.outputFormat", selection: $viewModel.outputFormat) {
                    ForEach(UpscaleExportViewModel.OutputFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .accessibilityLabel("upscale.outputFormat")
            }
            .pickerStyle(.menu)

            // Form内にラベルなしのTextを挟むとPicker行と整列が崩れるため、Form外に配置する
            if viewModel.engineKind == .aiSuperResolution {
                Text("upscale.scaleFactor.aiFixedNotice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let duration = viewModel.estimatedDuration {
                Label(
                    String(localized: "upscale.estimatedDuration \(Self.formattedDuration(duration))"),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text("upscale.cropNotApplied.note")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.exceedsSizeLimit {
                sizeLimitPrompt
            }

            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                    .accessibilityLabel("common.cancel")
                Button("upscale.start") { contentViewModel.startUpscaleExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canStart)
                    .accessibilityLabel("upscale.start")
            }
        }
    }

    // 上限超過時の3択:「倍率を下げる」「縮小して処理する」「中止」
    private var sizeLimitPrompt: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("upscale.sizeLimit.exceeded")
                .font(.caption)
                .foregroundStyle(.orange)

            HStack {
                Button("upscale.sizeLimit.reduceScale") { viewModel.reduceScale() }
                    .disabled(viewModel.engineKind == .aiSuperResolution || viewModel.scaleFactor == .double)
                    .accessibilityLabel("upscale.sizeLimit.reduceScale")
                Button("upscale.sizeLimit.downscaleThenProcess") { viewModel.acceptDownscaledProcessing() }
                    .accessibilityLabel("upscale.sizeLimit.downscaleThenProcess")
                Button("upscale.sizeLimit.abort", role: .cancel) { dismiss() }
                    .accessibilityLabel("upscale.sizeLimit.abort")
            }
        }
        .padding(Spacing.medium)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: CornerRadius.medium))
    }

    // MARK: - 実行中

    private var runningView: some View {
        VStack(spacing: Spacing.xLarge) {
            ProgressView(value: progressFraction)
                .accessibilityLabel("upscale.progress")
                .accessibilityValue(Text(progressPercentText))

            if viewModel.state.isCancelling {
                Text("upscale.cancelling")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("common.cancel") { viewModel.cancel() }
                .disabled(viewModel.state.isCancelling)
                .accessibilityLabel("common.cancel")
        }
    }

    private var progressFraction: Double {
        if case .running(let fraction) = viewModel.state { return fraction }
        return 0
    }

    private var progressPercentText: String {
        "\(Int(progressFraction * 100))%"
    }

    // MARK: - 完了

    private func finishedView(url: URL) -> some View {
        VStack(spacing: Spacing.xLarge) {
            Label("upscale.finished.title", systemImage: "checkmark.circle")
                .font(.headline)

            Text(url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                ExternalAppMenu(
                    apps: contentViewModel.externalApps,
                    onSelect: { adapter in contentViewModel.openInExternalApp(url: url, adapter: adapter) }
                )

                Button("upscale.finished.revealInFinder") { contentViewModel.revealUpscaleOutputInFinder() }
                    .accessibilityLabel("upscale.finished.revealInFinder")

                Spacer()

                Button("common.close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("common.close")
            }
        }
    }

    // MARK: - 失敗

    private func failedView(error: ShootLogError) -> some View {
        VStack(spacing: Spacing.xLarge) {
            Label("upscale.failed.title", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.red)

            Text(error.errorDescription ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("common.close") { dismiss() }
                    .accessibilityLabel("common.close")
                Button("upscale.failed.retry") { viewModel.state = .configuring }
                    .accessibilityLabel("upscale.failed.retry")
            }
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? ""
    }
}

private extension UpscaleExportViewModel.State {
    var isCancelling: Bool {
        if case .cancelling = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
