import AppKit
import Foundation

// 現像書き出しジョブの所有・NSSavePanel 提示・入力ファイルのセキュリティスコープ管理。
// 超解像書き出し（ContentViewModel+Upscale.swift）と同じ設計で、フォルダを閉じる／
// アプリ終了時にのみ中断する
extension ContentViewModel {

    // MARK: - シート表示

    func presentDevelopExport() {
        guard selectedPhoto != nil else { return }
        developExportViewModel = DevelopExportViewModel()
        isDevelopExportPresented = true
    }

    func dismissDevelopExport() {
        isDevelopExportPresented = false
    }

    // MARK: - 書き出し開始

    func startDevelopExport() {
        guard let photo = selectedPhoto, let viewModel = developExportViewModel else { return }

        let panel = NSSavePanel()
        panel.message = String(localized: "develop.export.savePanel.message")
        panel.prompt = String(localized: "develop.export.savePanel.prompt")
        panel.allowedContentTypes = [viewModel.outputFormat.utType]
        panel.nameFieldStringValue = Self.suggestedDevelopFileName(for: photo, format: viewModel.outputFormat)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try UpscaleOutputDestination.validate(
                destination: destination,
                currentFolder: currentFolderURL,
                photoURLs: photos.map(\.fileURL)
            )
            try beginDevelopExportInputAccess(for: photo.fileURL)
        } catch let shootLogError as ShootLogError {
            viewModel.state = .failed(shootLogError)
            return
        } catch {
            viewModel.state = .failed(.folderAccessDenied)
            return
        }

        viewModel.state = .running
        let task = Task { [weak self] in
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
        developExportTask?.cancel()
        developExportTask = nil
        developExportViewModel = nil
        isDevelopExportPresented = false
        endDevelopExportInputAccess()
    }

    // MARK: - Private

    private func runDevelopExport(
        photo: Photo,
        destination: URL,
        viewModel: DevelopExportViewModel
    ) async {
        defer { endDevelopExportInputAccess() }

        let exporter = DevelopExporter()
        let parameters = currentDevelopSettings?.parameters ?? .neutral
        let rotation = currentEditInfo?.rotation ?? 0
        let cropRect = currentEditInfo?.cropRect

        do {
            try await exporter.export(
                source: photo.fileURL,
                destination: destination,
                parameters: parameters,
                rotation: rotation,
                cropRect: cropRect,
                contentType: viewModel.outputFormat.utType,
                jpegQuality: viewModel.jpegQuality.rawValue,
                currentFolder: currentFolderURL,
                folderPhotoURLs: photos.map(\.fileURL)
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

    private static func suggestedDevelopFileName(
        for photo: Photo,
        format: DevelopExportViewModel.OutputFormat
    ) -> String {
        let base = photo.fileURL.deletingPathExtension().lastPathComponent
        return "\(base)_edited.\(format.fileExtension)"
    }

    // 入力写真1枚ぶんの読み取りアクセス。フォルダ全体のスコープとは独立して確保する
    // （ContentViewModel+Upscale.swift の beginUpscaleInputAccess と同じ方式）
    private func beginDevelopExportInputAccess(for url: URL) throws {
        endDevelopExportInputAccess()
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
        developExportInputAccessURL = scopedURL
    }

    private func endDevelopExportInputAccess() {
        developExportInputAccessURL?.stopAccessingSecurityScopedResource()
        developExportInputAccessURL = nil
    }
}
