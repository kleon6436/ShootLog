import SwiftUI

/// 現像書き出しのモーダルシート。設定 → 実行中 → 完了 / 失敗 を状態で切り替える。
struct DevelopExportSheet: View {
    @Bindable var contentViewModel: ContentViewModel
    @Bindable var viewModel: DevelopExportViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.xLarge) {
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
        .frame(width: 400)
    }

    // MARK: - 設定

    private var configuringView: some View {
        VStack(alignment: .leading, spacing: Spacing.xLarge) {
            Text("develop.export.title")
                .font(.headline)

            Form {
                Picker("develop.export.format", selection: $viewModel.outputFormat) {
                    ForEach(DevelopExportViewModel.OutputFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .accessibilityLabel("develop.export.format")

                if viewModel.outputFormat == .jpeg {
                    Picker("develop.export.jpegQuality", selection: $viewModel.jpegQuality) {
                        ForEach(UpscaleExportViewModel.JPEGQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .accessibilityLabel("develop.export.jpegQuality")
                }

                Picker("develop.export.colorSpace", selection: $viewModel.colorSpace) {
                    ForEach(ExportColorSpace.allCases) { space in
                        Text(space.displayName).tag(space)
                    }
                }
                .accessibilityLabel("develop.export.colorSpace")
                .disabled(viewModel.applySuperResolution)

                if viewModel.applySuperResolution, viewModel.colorSpace != .sRGB {
                    Text("develop.export.colorSpace.superResolutionNote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                superResolutionSection

                Text("develop.export.editsBakedNote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .pickerStyle(.menu)
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                Button("develop.export.start") { contentViewModel.startDevelopExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canStart)
            }
        }
    }

    @ViewBuilder
    private var superResolutionSection: some View {
        Toggle("develop.export.superResolution", isOn: $viewModel.applySuperResolution)

        if viewModel.applySuperResolution {
            Picker("develop.export.superResolution.scale", selection: $viewModel.superResolutionScale) {
                ForEach(viewModel.availableSuperResolutionScales) { scale in
                    Text(scale.displayName).tag(scale)
                }
            }
            .accessibilityLabel("develop.export.superResolution.scale")

            if viewModel.exceedsSizeLimit {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("develop.export.superResolution.tooLarge")
                        .font(.caption)
                        .foregroundStyle(.red)
                    if viewModel.canReduceSuperResolutionScale {
                        Button("develop.export.superResolution.reduceScale") {
                            viewModel.reduceSuperResolutionScale()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - 実行中

    private var runningView: some View {
        VStack(spacing: Spacing.xLarge) {
            switch viewModel.stage {
            case .developing:
                ProgressView { Text("develop.export.stage.developing") }
                    .accessibilityLabel("develop.export.stage.developing")
            case .upscaling:
                ProgressView(value: viewModel.upscaleProgress) {
                    Text("develop.export.stage.upscaling")
                }
                .accessibilityLabel("develop.export.stage.upscaling")
            }

            if viewModel.state.isCancelling {
                Text("develop.export.cancelling")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("common.cancel") { viewModel.cancel() }
                .disabled(viewModel.state.isCancelling)
        }
    }

    // MARK: - 完了

    private func finishedView(url: URL) -> some View {
        VStack(spacing: Spacing.xLarge) {
            Label("develop.export.finished.title", systemImage: "checkmark.circle")
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

                Button("develop.export.finished.revealInFinder") {
                    contentViewModel.revealDevelopExportOutputInFinder()
                }

                Spacer()

                Button("common.close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - 失敗

    private func failedView(error: ShootLogError) -> some View {
        VStack(spacing: Spacing.xLarge) {
            Label("develop.export.failed.title", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.red)

            Text(error.errorDescription ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("common.close") { dismiss() }
                Button("develop.export.failed.retry") { viewModel.state = .configuring }
            }
        }
    }
}

private extension DevelopExportViewModel.State {
    var isCancelling: Bool {
        if case .cancelling = self { return true }
        return false
    }
}
