import AppKit
import Foundation
import ImageIO

// AI超解像書き出しジョブの所有・NSSavePanel提示・入力ファイルのセキュリティスコープ管理を担当する。
// 処理はモード切替・写真選択変更をまたいで継続し、currentFolderURLの変更（フォルダを閉じる）
// またはアプリ終了時にのみ中断する（中断はcurrentFolderURLのdidSet経由でcancelUpscaleExportIfNeeded()が呼ばれる）
extension ContentViewModel {
    // MARK: - シート表示

    // 選択中写真を対象に設定画面を表示する
    func presentUpscaleExport() {
        guard let photo = selectedPhoto else { return }
        let pixelSize = Self.readPixelSize(of: photo.fileURL)
        upscaleExportViewModel = UpscaleExportViewModel(inputPixelSize: pixelSize)
        isUpscaleExportPresented = true
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

        do {
            try UpscaleOutputDestination.validate(
                destination: destination,
                currentFolder: currentFolderURL,
                photoURLs: photos.map(\.fileURL)
            )
            try beginUpscaleInputAccess(for: photo.fileURL)
        } catch let shootLogError as ShootLogError {
            viewModel.state = .failed(shootLogError)
            return
        } catch {
            viewModel.state = .failed(.folderAccessDenied)
            return
        }

        viewModel.state = .running(0)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runUpscaleExport(photo: photo, destination: destination, viewModel: viewModel)
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
        upscaleExportTask?.cancel()
        upscaleExportTask = nil
        upscaleExportViewModel = nil
        isUpscaleExportPresented = false
        endUpscaleInputAccess()
    }

    // MARK: - Private

    private func runUpscaleExport(photo: Photo, destination: URL, viewModel: UpscaleExportViewModel) async {
        defer { endUpscaleInputAccess() }

        let descriptor = Self.descriptor(
            for: viewModel.engineKind,
            scaleFactor: viewModel.scaleFactor.rawValue
        )
        let engine = SuperResolutionModelCatalog.makeEngine(for: descriptor)
        let exporter = UpscaleExporter(engine: engine, descriptor: descriptor)

        let stream = AsyncStream<Double>.makeStream(of: Double.self)
        async let progressTask: Void = viewModel.consumeProgress(stream.stream)

        let result: Result<Void, Error>
        do {
            try await exporter.export(
                source: photo.fileURL,
                destination: destination,
                rotation: currentEditInfo?.rotation ?? 0,
                currentFolder: currentFolderURL,
                folderPhotoURLs: photos.map(\.fileURL),
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

    // AIモデルはまだ同梱されていない（Docs/SuperResolution_モデル選定.md 参照、実装予定はRealESRGAN系）。
    // .aiSuperResolutionを選んでもCoreMLSuperResolutionEngineがsuperResolutionModelUnavailableを
    // 投げるだけなので、失敗画面から.traditionalへ切り替えて再試行できる
    private static func descriptor(
        for engineKind: UpscaleExportViewModel.EngineKind,
        scaleFactor: Int
    ) -> SuperResolutionModelDescriptor {
        switch engineKind {
        case .traditional:
            SuperResolutionModelDescriptor(
                id: "lanczos",
                scaleFactor: scaleFactor,
                tileLayout: .scaled(by: scaleFactor),
                isTrainedAlgorithmicMedia: false
            )
        case .aiSuperResolution:
            // RealESRGANモデルは128→512px固定の4倍専用のため、呼び出し元のUI選択倍率(scaleFactor)は使わず、
            // モデル仕様に合わせて常に4倍で組み立てる（防御的ガード）
            SuperResolutionModelDescriptor(
                id: "realesrgan",
                scaleFactor: 4,
                tileLayout: .scaled(by: 4),
                isTrainedAlgorithmicMedia: true
            )
        }
    }

    private static func suggestedOutputFileName(for photo: Photo, format: UpscaleExportViewModel.OutputFormat) -> String {
        let base = photo.fileURL.deletingPathExtension().lastPathComponent
        return "\(base)_upscaled.\(format.fileExtension)"
    }

    // 入力写真1枚ぶんの読み取りアクセス。フォルダ全体の bookmarkScopedURL とは独立して
    // ブックマークを新規作成・解決する（フォルダの権限スコープが既に有効な間のみ作成できる）
    private func beginUpscaleInputAccess(for url: URL) throws {
        endUpscaleInputAccess()
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var isStale = false
        let scopedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard scopedURL.startAccessingSecurityScopedResource() else {
            throw ShootLogError.folderAccessDenied
        }
        upscaleInputAccessURL = scopedURL
    }

    private func endUpscaleInputAccess() {
        upscaleInputAccessURL?.stopAccessingSecurityScopedResource()
        upscaleInputAccessURL = nil
    }

    // ヘッダのみを読み取り、実ピクセル寸法を取得する（デコードは行わない軽量な確認）
    private static func readPixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
