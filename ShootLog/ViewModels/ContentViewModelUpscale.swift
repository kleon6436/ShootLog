import AppKit
import Foundation
import ImageIO

// AI超解像書き出しジョブの所有・NSSavePanel提示・入力ファイルのセキュリティスコープ管理を担当する。
// 処理はモード切替・写真選択変更・サブフォルダ移動をまたいで継続し、rootFolderURLの変更（フォルダを閉じる）
// またはアプリ終了時にのみ中断する（中断はrootFolderURLのdidSet経由でcancelUpscaleExportIfNeeded()が呼ばれる）
extension ContentViewModel {
    // 書き出しジョブの入力。ジョブ開始時点の値で固定し、実行中にサブフォルダへ移動しても
    // 保存先の検証（防御1・防御2）と回転・トリミングが開始時点のフォルダ・写真を基準に効くようにする
    struct UpscaleExportInput {
        let currentFolder: URL?
        let folderPhotoURLs: [URL]
        let rotation: Int
        let cropRect: CGRect?
    }

    // MARK: - シート表示

    // 選択中写真を対象に設定画面を表示する
    func presentUpscaleExport() {
        guard let photo = selectedPhoto else { return }
        guard PhotoActionAvailability(photo: photo).hasLocalOriginalFile else { return }
        // ヘッダ読み取りはファイルI/Oのため MainActor 外で行い、読み終えてからシートを出す
        let url = photo.fileURL
        let photoID = photo.id
        upscaleExportPresentTask?.cancel()
        upscaleExportPresentTask = Task { [weak self] in
            let pixelSize = await Task.detached(priority: .userInitiated) {
                ContentViewModel.readPixelSize(of: url)
            }.value
            // 読み取り中に写真が切り替わった・再要求された場合は古い結果でシートを出さない
            guard let self, !Task.isCancelled, self.selectedPhoto?.id == photoID else { return }
            self.upscaleExportPresentTask = nil
            self.upscaleExportViewModel = UpscaleExportViewModel(
                inputPixelSize: pixelSize,
                croppedInputPixelSize: Self.croppedUpscalePixelSize(
                    pixelSize, cropRect: self.currentEditInfo?.cropRect
                )
            )
            self.isUpscaleExportPresented = true
        }
    }

    /// トリミング矩形（正規化）を適用した実効ピクセルサイズ。回転は総画素数を変えないため考慮しない。
    private static func croppedUpscalePixelSize(_ size: CGSize?, cropRect: CGRect?) -> CGSize? {
        guard let size else { return nil }
        guard let cropRect,
              cropRect != CGRect(x: 0, y: 0, width: 1, height: 1),
              cropRect.width > 0, cropRect.height > 0 else {
            return size
        }
        return CGSize(width: size.width * cropRect.width, height: size.height * cropRect.height)
    }

    // シートを閉じる。実行中ジョブ自体はここでは止めない（モード切替と同様、継続対象の操作のため）
    func dismissUpscaleExport() {
        isUpscaleExportPresented = false
    }

    // MARK: - 書き出し開始

    // 「設定」段階の開始ボタンから呼ぶ。NSSavePanelで保存先を決定してから処理を開始する
    func startUpscaleExport() {
        guard let photo = selectedPhoto, let viewModel = upscaleExportViewModel, viewModel.canStart else { return }

        let panel = NSSavePanel()
        panel.message = String(localized: "upscale.savePanel.message")
        panel.prompt = String(localized: "upscale.savePanel.prompt")
        panel.allowedContentTypes = [viewModel.outputFormat.utType]
        panel.nameFieldStringValue = Self.suggestedOutputFileName(for: photo, format: viewModel.outputFormat)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // 入力写真1枚ぶんの読み取りアクセス。フォルダ全体の bookmarkScopedURL とは独立して
        // ブックマークを新規作成・解決する（SecurityScopedBookmark.startAccessingFreshBookmark）。
        // 解放はこのジョブ自身が行う。共有プロパティで持つと、前のジョブのキャンセル後の
        // 後始末が新しいジョブのスコープを止めてしまうため
        let input = UpscaleExportInput(
            currentFolder: currentFolderURL,
            folderPhotoURLs: photos.map(\.fileURL),
            rotation: currentEditInfo?.rotation ?? 0,
            cropRect: currentEditInfo?.cropRect
        )
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

        viewModel.state = .running(0)
        let task = Task { [weak self] in
            defer { inputAccessURL.stopAccessingSecurityScopedResource() }
            guard let self else { return }
            await self.runUpscaleExport(photo: photo, destination: destination, input: input, viewModel: viewModel)
        }
        upscaleExportTask?.cancel()
        upscaleExportTask = task
        viewModel.attach(task: task)
    }

    // 完了画面の「Finderで表示」用
    func revealUpscaleOutputInFinder() {
        guard case .finished(let url) = upscaleExportViewModel?.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - ジョブの中断（フォルダを閉じる・アプリ終了時のみ）

    func cancelUpscaleExportIfNeeded() {
        upscaleExportPresentTask?.cancel()
        upscaleExportPresentTask = nil
        upscaleExportTask?.cancel()
        upscaleExportTask = nil
        upscaleExportViewModel = nil
        isUpscaleExportPresented = false
        // 入力ファイルのスコープはキャンセルされたジョブ自身が終了時に解放する
    }

    // MARK: - 実行

    // 入力は startUpscaleExport が開始時点で固定した値だけを使い、実行中の currentFolderURL・photos・
    // currentEditInfo は読み直さない。テストから固定入力の扱いを確かめるため internal とする
    func runUpscaleExport(
        photo: Photo,
        destination: URL,
        input: UpscaleExportInput,
        viewModel: UpscaleExportViewModel
    ) async {
        guard let descriptor = Self.descriptor(
            for: viewModel.engineKind,
            scaleFactor: viewModel.scaleFactor.rawValue
        ) else {
            viewModel.state = .failed(.superResolutionModelUnavailable)
            return
        }
        let engine = SuperResolutionModelCatalog.makeEngine(for: descriptor)
        let exporter = UpscaleExporter(engine: engine, descriptor: descriptor)

        let stream = AsyncStream<Double>.makeStream(of: Double.self)
        async let progressTask: Void = viewModel.consumeProgress(stream.stream)

        let result: Result<Void, Error>
        do {
            try await exporter.export(
                source: photo.fileURL,
                destination: destination,
                rotation: input.rotation,
                cropRect: input.cropRect,
                currentFolder: input.currentFolder,
                folderPhotoURLs: input.folderPhotoURLs,
                jpegQuality: viewModel.jpegQuality.rawValue,
                progress: stream.continuation
            )
            result = .success(())
        } catch {
            result = .failure(error)
        }
        stream.continuation.finish()
        await progressTask

        switch result {
        case .success:
            viewModel.state = .finished(destination)
        case .failure(let error) where error is CancellationError:
            viewModel.state = .configuring
        case .failure(let error as ShootLogError):
            viewModel.state = .failed(error)
        case .failure:
            viewModel.state = .failed(.superResolutionExportFailed)
        }
    }

    // 4倍(realesr-general-x4v3)・2倍(RealESRGAN_x2plus)とも .mlpackage を同梱済みで、
    // AIエンジンはどちらの倍率でも実際に推論できる。UI側の選択肢
    // (UpscaleExportViewModel.availableScaleFactors)もカタログ登録済みの倍率に連動するため、
    // AI選択時にモデルが引けない倍率は通常のUI操作では発生しない
    static func descriptor(
        for engineKind: UpscaleExportViewModel.EngineKind,
        scaleFactor: Int
    ) -> SuperResolutionModelDescriptor? {
        switch engineKind {
        case .traditional:
            SuperResolutionModelCatalog.lanczos(scaleFactor: scaleFactor)
        case .aiSuperResolution:
            SuperResolutionModelCatalog.aiModel(forScaleFactor: scaleFactor)
        }
    }

    private static func suggestedOutputFileName(for photo: Photo, format: UpscaleExportViewModel.OutputFormat) -> String {
        let base = photo.fileURL.deletingPathExtension().lastPathComponent
        return "\(base)_upscaled.\(format.fileExtension)"
    }

    // ヘッダのみを読み取り、実ピクセル寸法を取得する（デコードは行わない軽量な確認）
    // バックグラウンドから呼ぶため nonisolated
    nonisolated private static func readPixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
