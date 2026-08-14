import CoreGraphics
import Foundation

/// 超解像エンジンの共通インターフェース。
/// 実装は入力画像をタイル分割し、`buffer` へ重み付き合成して書き込む
protocol SuperResolutionEngine: Sendable {
    /// カタログ上の識別子。永続化・メタデータ記録に使うため必ずASCII固定値にする
    var modelID: String { get }

    /// 出力の拡大倍率（横方向・縦方向で共通）
    var scaleFactor: Int { get }

    /// 実行可否と、実行に使う演算ユニットを返す
    func availability() async -> EngineAvailability

    /// 入力画像を拡大して `buffer` へ書き込む。
    /// - Parameters:
    ///   - input: センサー解像度の入力画像
    ///   - rotation: `EditInfo.rotation` 由来の 0 / 90 / 180 / 270。EXIF orientation は適用しない
    ///   - buffer: 回転適用後の寸法で確保済みの出力バッファ
    ///   - progress: 0.0〜1.0 の進捗を通知する継続
    func upscale(
        _ input: CGImage,
        rotation: Int,
        into buffer: OutputPixelBuffer,
        progress: AsyncStream<Double>.Continuation
    ) async throws
}

/// エンジンの実行可否。呼び出し側がフォールバックの要否を判断できるよう、
/// エンジン自身は自動フォールバックを行わずこの値を返すだけにする
enum EngineAvailability: Sendable, Equatable {
    case available(computeUnit: EngineComputeUnit)
    case unavailable(reason: EngineUnavailableReason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var computeUnit: EngineComputeUnit? {
        if case .available(let unit) = self { return unit }
        return nil
    }
}

/// 推論に使う演算ユニット。raw value は設定へ永続化するためASCII固定とし、
/// 表示名は `displayName` へ分離する
enum EngineComputeUnit: String, Sendable, CaseIterable {
    case all
    case cpuAndNeuralEngine
    case cpuAndGPU
    case cpuOnly

    var displayName: LocalizedStringResource {
        switch self {
        case .all: return "superResolution.computeUnit.all"
        case .cpuAndNeuralEngine: return "superResolution.computeUnit.cpuAndNeuralEngine"
        case .cpuAndGPU: return "superResolution.computeUnit.cpuAndGPU"
        case .cpuOnly: return "superResolution.computeUnit.cpuOnly"
        }
    }
}

/// エンジンが使えない理由。UI層が案内文を出し分けられるよう種別を区別する
enum EngineUnavailableReason: Sendable, Equatable {
    /// モデルファイルが同梱・ダウンロードされていない
    case modelNotInstalled
    /// モデルはあるがコンパイル・ロードに失敗した
    case modelLoadFailed
    /// 実行できる演算ユニットが1つも見つからなかった
    case noSupportedComputeUnit

    var displayName: LocalizedStringResource {
        switch self {
        case .modelNotInstalled: return "superResolution.unavailable.modelNotInstalled"
        case .modelLoadFailed: return "superResolution.unavailable.modelLoadFailed"
        case .noSupportedComputeUnit: return "superResolution.unavailable.noSupportedComputeUnit"
        }
    }
}

/// 超解像パイプライン全体で共有する色空間。
/// タイル単位の変換にのみ使い、全画素バッファに対しては変換しない
enum SuperResolutionColorSpace {
    static let sRGB: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)
}
