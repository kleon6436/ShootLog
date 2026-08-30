import CoreGraphics
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

    /// 実行中の段階。超解像を挟むときだけ 2 段になる。
    enum Stage {
        case developing
        case upscaling
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
    // 出力カラースペース。既定は sRGB。超解像を挟む場合は sRGB 固定（超解像パイプラインが sRGB 前提のため）
    var colorSpace: ExportColorSpace = .sRGB

    /// 実際に書き出しへ渡す出力カラースペース。超解像 ON のときは sRGB を強制する。
    var effectiveColorSpace: ExportColorSpace {
        applySuperResolution ? .sRGB : colorSpace
    }

    // MARK: - 超解像チェーン

    /// 現像結果へさらに超解像を適用するか。
    var applySuperResolution = false
    /// 超解像の拡大倍率。AI モデルは 2 倍・4 倍を同梱。
    var superResolutionScale: UpscaleExportViewModel.ScaleFactor = .double

    /// 入力（原本）のピクセルサイズ。上限判定に使う。取得できなければ判定しない。
    let inputPixelSize: CGSize?
    /// トリミング適用後の実効入力ピクセルサイズ。超解像の入力はこの寸法。
    let croppedInputPixelSize: CGSize?

    /// 実行中の段階と超解像段の進捗（0.0〜1.0）。
    private(set) var stage: Stage = .developing
    private(set) var upscaleProgress: Double = 0

    init(inputPixelSize: CGSize? = nil, croppedInputPixelSize: CGSize? = nil) {
        self.inputPixelSize = inputPixelSize
        self.croppedInputPixelSize = croppedInputPixelSize
    }

    /// AI モデルが同梱されている倍率のみ選べる。
    var availableSuperResolutionScales: [UpscaleExportViewModel.ScaleFactor] {
        UpscaleExportViewModel.ScaleFactor.allCases.filter {
            SuperResolutionModelCatalog.aiModel(forScaleFactor: $0.rawValue) != nil
        }
    }

    /// 選択倍率での概算出力ピクセル数。トリミング後の寸法を基準にする。
    var estimatedOutputPixelCount: Double? {
        guard let size = croppedInputPixelSize ?? inputPixelSize else { return nil }
        let factor = Double(superResolutionScale.rawValue * superResolutionScale.rawValue)
        return size.width * size.height * factor
    }

    /// 書き出しパイプラインの上限（`UpscaleExporter.maximumOutputMegapixels`）を超えるか。
    var exceedsSizeLimit: Bool {
        guard applySuperResolution, let estimated = estimatedOutputPixelCount else { return false }
        return estimated > Double(UpscaleExporter.maximumOutputMegapixels) * 1_000_000
    }

    /// 倍率を下げられるか（4 倍を選んでいて 2 倍が使えるとき）。
    var canReduceSuperResolutionScale: Bool {
        superResolutionScale == .quadruple && availableSuperResolutionScales.contains(.double)
    }

    /// 開始ボタンを有効にできるか。上限超過時はブロックする。
    var canStart: Bool { !exceedsSizeLimit }

    func reduceSuperResolutionScale() {
        guard canReduceSuperResolutionScale else { return }
        superResolutionScale = .double
    }

    // MARK: - 進捗

    /// 書き出し開始時に呼ぶ。まず現像段から始まる。
    func beginProcessing() {
        stage = .developing
        upscaleProgress = 0
    }

    /// 超解像段の進捗を受け取る。最初の通知で段階を `.upscaling` へ進める。
    func updateUpscaleProgress(_ fraction: Double) {
        guard case .running = state else { return }
        stage = .upscaling
        upscaleProgress = min(max(fraction, 0), 1)
    }

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
