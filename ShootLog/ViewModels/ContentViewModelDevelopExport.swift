import AppKit
import CoreGraphics
import Foundation
import ImageIO

// 現像書き出しジョブの所有・NSSavePanel 提示・入力ファイルのセキュリティスコープ管理。
// 超解像書き出し（ContentViewModelUpscale.swift）と同じ設計で、フォルダを閉じる／
// アプリ終了時にのみ中断する
extension ContentViewModel {
    // 書き出しジョブの入力。ジョブ開始時点の値で固定し、実行中にサブフォルダへ移動したり
    // 写真の選択が変わったりしても、保存先の検証（防御1・防御2）と現像内容が開始時点を基準に効くようにする
    struct DevelopExportInput {
        let currentFolder: URL?
        let folderPhotoURLs: [URL]
        let parameters: DevelopParameters
        let rotation: Int
        let cropRect: CGRect?
        let useRAWParameterMapping: Bool
        let usesManualLensCorrection: Bool
        let usesToneMaskedColorGrading: Bool
        let maskRasters: [UUID: CGImage]
    }

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
        let input = makeDevelopExportInput(for: photo)
        let inputAccessURL: URL
        do {
            try UpscaleOutputDestination.validate(
                destination: destination,
                currentFolder: input.currentFolder,
                photoURLs: input.folderPhotoURLs
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
            await self.runDevelopExport(photo: photo, destination: destination, input: input, viewModel: viewModel)
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

    // MARK: - 実行

    // ジョブ開始時点の状態から書き出し入力を組み立てる
    func makeDevelopExportInput(for photo: Photo) -> DevelopExportInput {
        let parameters = currentDevelopSettings?.parameters ?? .neutral
        // RAW かつ version 2（またはレコード無し）のときだけ露出・WB を CIRAWFilter へ委譲する。
        let useRAWMapping = ImageDevelopmentEngine.shared.isRAW(url: photo.fileURL)
            && (currentDevelopSettings?.usesRAWParameterMapping ?? true)
        return DevelopExportInput(
            currentFolder: currentFolderURL,
            folderPhotoURLs: photos.map(\.fileURL),
            parameters: parameters,
            rotation: currentEditInfo?.rotation ?? 0,
            cropRect: currentEditInfo?.cropRect,
            useRAWParameterMapping: useRAWMapping,
            usesManualLensCorrection: (currentDevelopSettings?.usesManualLensCorrection ?? true)
                && !(useRAWMapping && parameters.lensCorrectionEnabled),
            usesToneMaskedColorGrading: currentDevelopSettings?.usesToneMaskedColorGrading ?? true,
            maskRasters: MaskRasterResolving.resolve(
                masks: parameters.masks,
                rasters: currentDevelopSettings?.maskRasters ?? []
            )
        )
    }

    // 入力は startDevelopExport が開始時点で固定した値だけを使い、実行中の currentFolderURL・photos・
    // currentEditInfo・currentDevelopSettings は読み直さない。テストから固定入力の扱いを確かめるため internal とする
    func runDevelopExport(
        photo: Photo,
        destination: URL,
        input: DevelopExportInput,
        viewModel: DevelopExportViewModel
    ) async {
        let exporter = DevelopExporter()

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
            let asShot = input.usesToneMaskedColorGrading
                ? await asShotWhiteBalance(for: photo)
                : nil
            try await exporter.export(
                source: photo.fileURL,
                destination: destination,
                parameters: input.parameters,
                rotation: input.rotation,
                cropRect: input.cropRect,
                contentType: viewModel.outputFormat.utType,
                jpegQuality: viewModel.jpegQuality.rawValue,
                outputColorSpace: viewModel.effectiveColorSpace.cgColorSpace,
                useRAWParameterMapping: input.useRAWParameterMapping,
                usesManualLensCorrection: input.usesManualLensCorrection,
                usesToneMaskedColorGrading: input.usesToneMaskedColorGrading,
                asShotWhiteBalance: asShot,
                maskRasters: input.maskRasters,
                superResolution: superResolution,
                currentFolder: input.currentFolder,
                folderPhotoURLs: input.folderPhotoURLs,
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
