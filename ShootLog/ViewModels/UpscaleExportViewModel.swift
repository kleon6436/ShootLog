import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// AI超解像書き出しシートの状態管理。実処理はContentViewModel+Upscale.swiftが
// SuperResolutionEngineを呼び出して駆動し、進捗はAsyncStream<Double>経由でここへ流し込む
@Observable
@MainActor
final class UpscaleExportViewModel {
    enum State {
        case configuring
        case running(Double)
        case cancelling
        case finished(URL)
        case failed(ShootLogError)
    }

    enum ScaleFactor: Int, CaseIterable, Identifiable {
        case double = 2
        case quadruple = 4

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .double: String(localized: "upscale.scaleFactor.double")
            case .quadruple: String(localized: "upscale.scaleFactor.quadruple")
            }
        }
    }

    enum EngineKind: String, CaseIterable, Identifiable {
        case aiSuperResolution
        case traditional

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .aiSuperResolution: String(localized: "upscale.engine.aiSuperResolution")
            case .traditional: String(localized: "upscale.engine.traditional")
            }
        }
    }

    enum OutputFormat: String, CaseIterable, Identifiable {
        case jpeg
        case tiff
        case png

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .jpeg: String(localized: "upscale.outputFormat.jpeg")
            case .tiff: String(localized: "upscale.outputFormat.tiff")
            case .png: String(localized: "upscale.outputFormat.png")
            }
        }

        var utType: UTType {
            switch self {
            case .jpeg: .jpeg
            case .tiff: .tiff
            case .png: .png
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .tiff: "tiff"
            case .png: "png"
            }
        }
    }

    // JPEGの圧縮品質。rawValueはそのままkCGImageDestinationLossyCompressionQualityへ渡す
    enum JPEGQuality: Double, CaseIterable, Identifiable {
        case highest = 1.0
        case high = 0.85
        case medium = 0.65
        case low = 0.4

        var id: Double { rawValue }

        var displayName: String {
            switch self {
            case .highest: String(localized: "upscale.jpegQuality.highest")
            case .high: String(localized: "upscale.jpegQuality.high")
            case .medium: String(localized: "upscale.jpegQuality.medium")
            case .low: String(localized: "upscale.jpegQuality.low")
            }
        }
    }

    var state: State = .configuring

    var scaleFactor: ScaleFactor = .quadruple {
        didSet {
            guard oldValue != scaleFactor else { return }
            acceptsDownscaledProcessing = false
        }
    }

    // AIモデルは4倍専用固定(128→512px)のため、AI選択時は倍率を強制する
    var engineKind: EngineKind = .aiSuperResolution {
        didSet {
            guard engineKind == .aiSuperResolution else { return }
            scaleFactor = .quadruple
        }
    }
    var outputFormat: OutputFormat = .jpeg

    // 品質はフォーマット非依存の設定として保持する（TIFF/PNGへ切り替えて戻しても選択を失わない）
    var jpegQuality: JPEGQuality = .highest

    // 入力写真のピクセルサイズ。上限判定・所要時間見積りに使う（取得できない場合は概算を出さない）
    let inputPixelSize: CGSize?

    // 「縮小して処理する」を選んだ場合に true。scaleFactorを変更すると選び直しが必要なためリセットする
    var acceptsDownscaledProcessing = false

    // 出力ピクセル数の概算上限。AI版・従来方式ともに実際の書き出しパイプラインが許容する上限
    // （UpscaleExporter.maximumOutputMegapixels）と同じ基準にする。エンジンごとに別の目安値を
    // 持つと、UIでは通れたのに書き出し時にsuperResolutionOutputTooLargeで失敗する、または
    // 逆に実際は処理できる組み合わせをUIが不必要に弾く、という食い違いが起きる。
    // AI版は4倍固定で倍率を下げて回避できないため、大きめの写真では常に超過扱いになりうるが、
    // それは書き出しパイプラインの実際のメモリ制約を正しく反映した結果であり、UI側の判定不備ではない
    private static let maxOutputPixelCount = Double(UpscaleExporter.maximumOutputMegapixels) * 1_000_000
    // 所要時間見積りに使う概算処理速度（px/秒、目安値）。同上
    private static let assumedPixelsPerSecond: Double = 2_000_000

    init(inputPixelSize: CGSize?) {
        self.inputPixelSize = inputPixelSize
    }

    // AI版はモデルが4倍専用固定のため選択肢を1つに絞る
    var availableScaleFactors: [ScaleFactor] {
        engineKind == .aiSuperResolution ? [.quadruple] : ScaleFactor.allCases
    }

    // 選択中の倍率での概算出力ピクセル数
    var estimatedOutputPixelCount: Double? {
        guard let inputPixelSize else { return nil }
        let factor = Double(scaleFactor.rawValue * scaleFactor.rawValue)
        return inputPixelSize.width * inputPixelSize.height * factor
    }

    // 概算上限を超えるかどうか。サイズ不明時は判定できないため false（呼び出し側でブロックしない）
    var exceedsSizeLimit: Bool {
        guard let estimatedOutputPixelCount else { return false }
        return estimatedOutputPixelCount > Self.maxOutputPixelCount
    }

    // 開始ボタンを有効にできるかどうか。上限超過時は「縮小して処理する」への同意が必要
    var canStart: Bool {
        !exceedsSizeLimit || acceptsDownscaledProcessing
    }

    // 概算所要時間（秒）。目安値のため表示は「約」を付ける前提
    var estimatedDuration: TimeInterval? {
        guard let estimatedOutputPixelCount else { return nil }
        return estimatedOutputPixelCount / Self.assumedPixelsPerSecond
    }

    // 上限超過時の選択肢: 倍率を下げる
    func reduceScale() {
        guard engineKind != .aiSuperResolution else { return }
        guard scaleFactor == .quadruple else { return }
        scaleFactor = .double
    }

    // 上限超過時の選択肢: 縮小して処理する
    func acceptDownscaledProcessing() {
        acceptsDownscaledProcessing = true
    }

    // ContentViewModel+Upscale.swiftが処理開始時に代入し、cancel()から参照できるようにする
    private var task: Task<Void, Never>?

    func attach(task: Task<Void, Never>) {
        self.task = task
    }

    // 実行中のみキャンセルを受け付ける。状態はcancellingへ遷移し、実処理側のTaskキャンセルを待つ
    func cancel() {
        guard case .running = state else { return }
        state = .cancelling
        task?.cancel()
    }

    // 進捗ストリームを消費してstateへ反映する。running以外に遷移済みなら更新しない
    func consumeProgress(_ stream: AsyncStream<Double>) async {
        for await fraction in stream {
            guard case .running = state else { continue }
            state = .running(fraction)
        }
    }
}
