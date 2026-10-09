import AppKit
import CoreGraphics
import Foundation
import ImageIO

// 現像書き出しジョブの所有・NSSavePanel 提示・入力ファイルのセキュリティスコープ管理。
// 超解像書き出し（ContentViewModelUpscale.swift）と同じ設計で、フォルダを閉じる／
// アプリ終了時にのみ中断する
extension ContentViewModel {

    // MARK: - シート表示

    func presentDevelopExport() {
        guard let photo = selectedPhoto else { return }
        guard PhotoActionAvailability(photo: photo).hasLocalOriginalFile else { return }
        // ヘッダ読み取りはファイルI/Oのため MainActor 外で行い、読み終えてからシートを出す
        let url = photo.fileURL
        let photoID = photo.id
        developExportPresentTask?.cancel()
        developExportPresentTask = Task { [weak self] in
            let inputSize = await Task.detached(priority: .userInitiated) {
                ContentViewModel.readDevelopInputPixelSize(of: url)
            }.value
            // 読み取り中に写真が切り替わった・再要求された場合は古い結果でシートを出さない
            guard let self, !Task.isCancelled, self.selectedPhoto?.id == photoID else { return }
            self.developExportPresentTask = nil
            self.developExportViewModel = DevelopExportViewModel(
                inputPixelSize: inputSize,
                croppedInputPixelSize: Self.croppedPixelSize(inputSize, cropRect: self.currentEditInfo?.cropRect)
            )
            self.isDevelopExportPresented = true
        }
    }

    func dismissDevelopExport() {
        isDevelopExportPresented = false
    }

    // MARK: - 書き出し開始

    func startDevelopExport() {
        guard let photo = selectedPhoto, let viewModel = developExportViewModel, viewModel.canStart else { return }

        let panel = NSSavePanel()
        panel.message = String(localized: "develop.export.savePanel.message")
        panel.prompt = String(localized: "develop.export.savePanel.prompt")
        panel.allowedContentTypes = [viewModel.outputFormat.utType]
        panel.nameFieldStringValue = Self.suggestedDevelopFileName(for: photo, format: viewModel.outputFormat)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // 入力写真1枚ぶんの読み取りアクセス。フォルダ全体のスコープとは独立して確保し
        // （ContentViewModelUpscale.swift と同じく SecurityScopedBookmark を使う）、
        // 解放はこのジョブ自身が行う。共有プロパティで持つと、前のジョブのキャンセル後の
        // 後始末が新しいジョブのスコープを止めてしまうため
        let inputAccessURL: URL
        do {
            try UpscaleOutputDestination.validate(
                destination: destination,
                currentFolder: currentFolderURL,
                photoURLs: photos.map(\.fileURL)
            )
            inputAccessURL = try SecurityScopedBookmark.startAccessingFreshBookmark(for: photo.fileURL)
        } catch let shootLogError as ShootLogError {
            viewModel.state = .failed(shootLogError)
            return
        } catch {
            viewModel.state = .failed(.folderAccessDenied)
            return
        }

        viewModel.state = .running
        let task = Task { [weak self] in
            defer { inputAccessURL.stopAccessingSecurityScopedResource() }
            guard let self else { return }
            await self.runDevelopExport(photo: photo, destination: destination, viewModel: viewModel)
        }
        developExportTask?.cancel()
        developExportTask = task
        viewModel.attach(task: task)
    }

    func revealDevelopExportOutputInFinder() {
        guard case .finished(let url) = developExportViewModel?.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - ジョブの中断（フォルダを閉じる・アプリ終了時のみ）

    func cancelDevelopExportIfNeeded() {
        developExportPresentTask?.cancel()
        developExportPresentTask = nil
        developExportTask?.cancel()
        developExportTask = nil
        developExportViewModel = nil
        isDevelopExportPresented = false
        // 入力ファイルのスコープはキャンセルされたジョブ自身が終了時に解放する
    }

    // MARK: - Private

    private func runDevelopExport(
        photo: Photo,
        destination: URL,
        viewModel: DevelopExportViewModel
    ) async {
        let exporter = DevelopExporter()
        let parameters = currentDevelopSettings?.parameters ?? .neutral
        let rotation = currentEditInfo?.rotation ?? 0
        let cropRect = currentEditInfo?.cropRect
        // RAW かつ version 2（またはレコード無し）のときだけ露出・WB を CIRAWFilter へ委譲する。
        let useRAWMapping = ImageDevelopmentEngine.shared.isRAW(url: photo.fileURL)
            && (currentDevelopSettings?.usesRAWParameterMapping ?? true)
        let usesManualLens = (currentDevelopSettings?.usesManualLensCorrection ?? true)
            && !(useRAWMapping && parameters.lensCorrectionEnabled)
        let usesToneMasked = (currentDevelopSettings?.usesToneMaskedColorGrading ?? true)
        let maskRasters = MaskRasterResolving.resolve(
            masks: parameters.masks,
            rasters: currentDevelopSettings?.maskRasters ?? []
        )

        viewModel.beginProcessing()

        var superResolution: DevelopExporter.SuperResolutionRequest?
        if viewModel.applySuperResolution {
            guard let descriptor = SuperResolutionModelCatalog.aiModel(
                forScaleFactor: viewModel.superResolutionScale.rawValue
            ) else {
                viewModel.state = .failed(.superResolutionModelUnavailable)
                return
            }
            superResolution = DevelopExporter.SuperResolutionRequest(
                engine: SuperResolutionModelCatalog.makeEngine(for: descriptor),
                descriptor: descriptor
            )
        }

        do {
            let asShot = usesToneMasked
                ? await asShotWhiteBalance(for: photo)
                : nil
            try await exporter.export(
                source: photo.fileURL,
                destination: destination,
                parameters: parameters,
                rotation: rotation,
                cropRect: cropRect,
                contentType: viewModel.outputFormat.utType,
                jpegQuality: viewModel.jpegQuality.rawValue,
                outputColorSpace: viewModel.effectiveColorSpace.cgColorSpace,
                useRAWParameterMapping: useRAWMapping,
                usesManualLensCorrection: usesManualLens,
                usesToneMaskedColorGrading: usesToneMasked,
                asShotWhiteBalance: asShot,
                maskRasters: maskRasters,
                superResolution: superResolution,
                currentFolder: currentFolderURL,
                folderPhotoURLs: photos.map(\.fileURL),
                upscaleProgress: { [weak viewModel] fraction in
                    Task { @MainActor in viewModel?.updateUpscaleProgress(fraction) }
                }
            )
            viewModel.state = .finished(destination)
        } catch is CancellationError {
            viewModel.state = .configuring
        } catch let error as ShootLogError {
            viewModel.state = .failed(error)
        } catch {
            viewModel.state = .failed(.developExportFailed)
        }
    }

    // MARK: - 入力サイズの取得

    // バックグラウンドから呼ぶため nonisolated
    nonisolated private static func readDevelopInputPixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// トリミング矩形（正規化）を適用した実効ピクセルサイズ。回転は総画素数を変えないため考慮しない。
    private static func croppedPixelSize(_ size: CGSize?, cropRect: CGRect?) -> CGSize? {
        guard let size else { return nil }
        guard let cropRect,
              cropRect != CGRect(x: 0, y: 0, width: 1, height: 1),
              cropRect.width > 0, cropRect.height > 0 else {
            return size
        }
        return CGSize(width: size.width * cropRect.width, height: size.height * cropRect.height)
    }

    private static func suggestedDevelopFileName(
        for photo: Photo,
        format: DevelopExportViewModel.OutputFormat
    ) -> String {
        let base = photo.fileURL.deletingPathExtension().lastPathComponent
        return "\(base)_edited.\(format.fileExtension)"
    }
}
