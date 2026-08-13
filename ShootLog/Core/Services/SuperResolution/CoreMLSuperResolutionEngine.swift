import CoreGraphics
import CoreImage
import CoreML
import Foundation

/// Core ML モデルによる超解像エンジン。
///
/// `realesr-general-x4v3`（SRVGGNetCompact, BSD-3-Clause）をCore ML化したモデルを
/// `ShootLog/Resources/Models/realesrgan.mlpackage` として同梱している
/// （変換手順は `Tools/CoreML/convert_model.py`、ライセンス根拠は
/// `Docs/SuperResolution_モデル選定.md` を参照）。
/// 呼び出し側が Lanczos へ切り替えられるよう、このエンジン自身は自動フォールバックしない
struct CoreMLSuperResolutionEngine: SuperResolutionEngine {
    let modelID: String
    let scaleFactor: Int
    let layout: TileLayout

    /// コンパイル済みモデルの位置。未同梱なら nil
    let modelURL: URL?

    init(descriptor: SuperResolutionModelDescriptor, modelURL: URL? = nil) {
        self.modelID = descriptor.id
        self.scaleFactor = descriptor.scaleFactor
        self.layout = descriptor.tileLayout
        self.modelURL = modelURL ?? Self.bundledModelURL(for: descriptor.id)
    }

    /// アプリバンドル内のコンパイル済みモデルを探す
    static func bundledModelURL(for modelID: String) -> URL? {
        Bundle.main.url(forResource: modelID, withExtension: "mlmodelc")
    }

    // MARK: - 演算ユニットの探索

    /// 探索順。Apple Neural Engine が最も省電力・高速なため先に試し、
    /// 使えない構成では GPU、最後に CPU のみへ落とす
    static let probeOrder: [EngineComputeUnit] = [.cpuAndNeuralEngine, .cpuAndGPU, .all, .cpuOnly]

    static func mlComputeUnits(for unit: EngineComputeUnit) -> MLComputeUnits {
        switch unit {
        case .all: return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuOnly: return .cpuOnly
        }
    }

    /// 実際にモデルをロードできた最初の演算ユニットを返す
    static func probeComputeUnit(modelURL: URL) async -> EngineComputeUnit? {
        for candidate in probeOrder {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = mlComputeUnits(for: candidate)
            if (try? await MLModel.load(contentsOf: modelURL, configuration: configuration)) != nil {
                return candidate
            }
        }
        return nil
    }

    func availability() async -> EngineAvailability {
        guard let modelURL else { return .unavailable(reason: .modelNotInstalled) }
        guard let unit = await Self.probeComputeUnit(modelURL: modelURL) else {
            return .unavailable(reason: .noSupportedComputeUnit)
        }
        return .available(computeUnit: unit)
    }

    // MARK: - NaN 検出ガード

    /// 推論結果に NaN / Inf が含まれていないか検査する。
    /// 量子化モデルでは特定の入力で発散することがあり、そのまま 8bit へ丸めると
    /// 黒や白のブロックとして出力へ焼き付いてしまうため、検出したらタイル単位で失敗させる
    static func containsNonFinite(_ values: UnsafeBufferPointer<Float>) -> Bool {
        for value in values where !value.isFinite { return true }
        return false
    }

    static func containsNonFinite(_ array: MLMultiArray) -> Bool {
        guard array.dataType == .float32 else { return false }
        return array.withUnsafeBufferPointer(ofType: Float.self) { containsNonFinite($0) }
    }

    // MARK: - 実行

    func upscale(
        _ input: CGImage,
        rotation: Int,
        into buffer: OutputPixelBuffer,
        progress: AsyncStream<Double>.Continuation
    ) async throws {
        guard let modelURL else { throw ShootLogError.superResolutionModelUnavailable }
        guard let unit = await Self.probeComputeUnit(modelURL: modelURL) else {
            throw ShootLogError.superResolutionModelUnavailable
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.mlComputeUnits(for: unit)
        let model = SendableModel(try MLModel(contentsOf: modelURL, configuration: configuration))

        let runner = TiledInferenceRunner(layout: layout)
        let context = Self.sharedContext
        let outputSize = layout.outputTileSize

        try await runner.run(input: input, rotation: rotation, into: buffer, progress: progress) { tile in
            try Self.infer(tile: tile, model: model.value, outputSize: outputSize, context: context)
        }
    }

    /// `MLModel` は `Sendable` に準拠していないが、Appleのドキュメント上
    /// 予測メソッドはスレッドセーフに呼び出せるとされている（本エンジンではタイルループが
    /// 直列実行のため、そもそも並行アクセスは発生しない）。`nonisolated async` クロージャへ
    /// キャプチャさせるためのラッパー
    private struct SendableModel: @unchecked Sendable {
        let value: MLModel
        init(_ value: MLModel) { self.value = value }
    }

    // MARK: - タイル単位の推論

    private static let sharedContext = CIContext(options: [.workingColorSpace: SuperResolutionColorSpace.sRGB as Any])

    /// タイル1枚をモデルへ通す。CVPixelBufferへの変換・実行・CGImageへの読み戻しをここで行う
    static func infer(tile: CGImage, model: MLModel, outputSize: Int, context: CIContext) throws -> CGImage {
        let inputBuffer = try MLFeatureValue(
            cgImage: tile,
            pixelsWide: tile.width,
            pixelsHigh: tile.height,
            pixelFormatType: kCVPixelFormatType_32ARGB,
            options: nil
        )
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": inputBuffer])
        let result = try model.prediction(from: provider)

        guard let outputFeature = result.featureValue(for: "output"),
              let outputPixelBuffer = outputFeature.imageBufferValue else {
            throw ShootLogError.superResolutionFailed(reason: "model output missing pixel buffer")
        }

        let ciImage = CIImage(cvPixelBuffer: outputPixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: CGFloat(outputSize), height: CGFloat(outputSize))
        guard let colorSpace = SuperResolutionColorSpace.sRGB,
              let outputImage = context.createCGImage(ciImage, from: rect, format: .RGBA8, colorSpace: colorSpace) else {
            throw ShootLogError.superResolutionFailed(reason: "output pixel buffer readback failed")
        }
        return outputImage
    }
}
