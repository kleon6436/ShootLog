import CoreImage
import Foundation

/// 手動レンズ補正（歪曲・周辺光量・色収差）を 1 つの `CIImage -> CIImage` 変換にまとめるフィルタ。
///
/// - 歪曲補正: Metal で書いた `[[stitchable]]` ワープ関数（`LensDistortion.ci.metal`）を
///   `CIWarpKernel(functionName:fromMetalLibraryData:)` でロードする。ビルドは通常の
///   `default.metallib` で、CIKernel 専用のビルドフラグは不要。
/// - 周辺光量・色収差: Phase 5-2 で標準 `CIFilter` の組み合わせとして実装する。
///
/// metallib はアプリバンドルの `Contents/Resources/default.metallib` から解決する。
/// 単体テストはアプリをホストに実行されるため `Bundle(for:)` / `Bundle.main` とも
/// アプリバンドルを指し、同じ metallib が使える（プラン Phase 5 の M-8）。
/// Phase 5-1 の時点では歪曲カーネルは恒等ワープで、`apply` は入力をそのまま返す。
enum LensCorrectionFilter {

    /// カーネルのロード結果。生成コストが高く不変なので一度だけ評価する。
    private static let loaded: (kernel: CIWarpKernel?, failureReason: String?) = loadDistortionKernel()

    /// 歪曲補正カーネル。metallib のロードに失敗した場合は `nil`（歪曲補正はスキップされる）。
    static var distortionKernel: CIWarpKernel? { loaded.kernel }

    /// カーネルのロードに失敗した理由（デバッグ用）。成功時は `nil`。
    static var loadFailureReason: String? { loaded.failureReason }

    /// レンズ補正を適用した画像を返す。Phase 5-1 では常に入力をそのまま返す。
    static func apply(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        image
    }

    // MARK: - metallib ロード

    private static func loadDistortionKernel() -> (kernel: CIWarpKernel?, failureReason: String?) {
        let candidates = [Bundle(for: BundleToken.self), Bundle.main]
        guard let url = candidates.lazy
            .compactMap({ $0.url(forResource: "default", withExtension: "metallib") })
            .first else {
            return (nil, "default.metallib が見つからない (searched: \(candidates.map(\.bundlePath)))")
        }
        do {
            let data = try Data(contentsOf: url)
            let kernel = try CIWarpKernel(functionName: "lensDistortionWarp", fromMetalLibraryData: data)
            return (kernel, nil)
        } catch {
            return (nil, "CIWarpKernel 生成失敗 (\(url.lastPathComponent)): \(error)")
        }
    }

    /// `Bundle(for:)` で自ターゲットのバンドルを引くためのアンカー。
    private final class BundleToken {}
}
