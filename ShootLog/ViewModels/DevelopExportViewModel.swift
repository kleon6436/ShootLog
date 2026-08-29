import Foundation
import UniformTypeIdentifiers

/// 現像書き出しシートの状態管理。実処理は `ContentViewModel+DevelopExport.swift` が
/// `DevelopExporter` を呼んで駆動する。
@Observable
@MainActor
final class DevelopExportViewModel {

    enum State {
        case configuring
        case running
        case cancelling
        case finished(URL)
        case failed(ShootLogError)
    }

    /// 出力形式。可逆な TIFF と非可逆な JPEG の 2 種。
    enum OutputFormat: String, CaseIterable, Identifiable {
        case jpeg
        case tiff

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .jpeg: String(localized: "develop.export.format.jpeg")
            case .tiff: String(localized: "develop.export.format.tiff")
            }
        }

        var utType: UTType {
            switch self {
            case .jpeg: .jpeg
            case .tiff: .tiff
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .tiff: "tiff"
            }
        }
    }

    var state: State = .configuring
    var outputFormat: OutputFormat = .jpeg
    // JPEG 品質は超解像書き出しと同じ 4 段階 enum を再利用する
    var jpegQuality: UpscaleExportViewModel.JPEGQuality = .highest

    private var task: Task<Void, Never>?

    func attach(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        guard case .running = state else { return }
        state = .cancelling
        task?.cancel()
    }
}
