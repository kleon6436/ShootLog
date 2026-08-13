import CoreGraphics
import CoreML
import Foundation

/// Core ML モデルによる超解像エンジン。
///
/// 実モデル（`.mlpackage`）はまだ同梱されていないため、現時点では `upscale` は必ず
/// `.superResolutionModelUnavailable` を投げる。演算ユニットの探索と NaN 検出ガードは
/// モデル同梱後にそのまま使えるよう先に実装してある。
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
        // モデル未同梱のため実行できない。呼び出し側が availability() を見て
        // Lanczos へ切り替える想定で、ここでは黙ってフォールバックしない
        throw ShootLogError.superResolutionModelUnavailable
    }
}
