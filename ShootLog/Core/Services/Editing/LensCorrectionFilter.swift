import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 手動レンズ補正（歪曲・周辺光量・色収差）を 1 つの `CIImage -> CIImage` 変換にまとめるフィルタ。
///
/// - 歪曲補正: Metal で書いた `[[stitchable]]` ワープ関数（`LensDistortion.ci.metal`）を
///   `CIWarpKernel(functionName:fromMetalLibraryData:)` でロードする。ビルドは通常の
///   `default.metallib` で、CIKernel 専用のビルドフラグは不要。
/// - 周辺光量補正: `CIVignetteEffect` に負の intensity を与えて四隅を持ち上げる。
/// - 色収差補正: R / B チャンネルを中心基準で僅かに拡大縮小し、G と合成し直す（横色収差）。
///
/// 3 つの補正量はいずれも -100...100 で、すべて 0 のとき入力をそのまま返す（恒等）。
/// 座標は正規化量（画像 extent に対する相対）で扱うため、プレビュー縮小とフル解像度で
/// 効き方が一致する（WYSIWYG）。
///
/// metallib はアプリバンドルの `Contents/Resources/default.metallib` から解決する。
/// 単体テストはアプリをホストに実行されるため `Bundle(for:)` / `Bundle.main` とも
/// アプリバンドルを指し、同じ metallib が使える（プラン Phase 5 の M-8）。
enum LensCorrectionFilter {

    // MARK: - 係数マッピング

    /// 歪曲補正量 ±100 に対する 2 次係数 `k1` の振り幅。正で樽型を補正する。
    private static let distortionK1Span = 0.30
    /// 同 4 次係数 `k2` の振り幅。高次項は控えめに。
    private static let distortionK2Span = 0.05
    /// 周辺光量補正量 ±100 に対する `CIVignetteEffect.intensity` の振り幅。
    private static let vignetteIntensitySpan = 1.2
    /// `CIVignetteEffect` の効き始め半径と減衰。
    private static let vignetteRadius: Float = 1.6
    private static let vignetteFalloff: Float = 0.5
    /// 色収差補正量 ±100 に対する R / B チャンネルの拡大縮小率の振り幅（横色収差、最大 ±1%）。
    private static let chromaticAberrationScaleSpan = 0.01

    /// この絶対値以下の補正量は「中立」とみなしてフィルタを挟まない。
    private static let neutralThreshold = 1e-6

    // MARK: - 公開 API

    /// 3 つのレンズ補正を順に適用した画像を返す。すべての補正量が 0 なら入力をそのまま返す。
    ///
    /// 適用順は「歪曲 → 色収差 → 周辺光量」。幾何変形を先に済ませてから輝度補正を掛ける。
    static func corrected(
        _ image: CIImage,
        distortion: Double,
        vignette: Double,
        chromaticAberration: Double
    ) -> CIImage {
        var result = image
        result = applyDistortion(result, amount: distortion)
        result = applyChromaticAberration(result, amount: chromaticAberration)
        result = applyVignette(result, amount: vignette)
        return result
    }

    // MARK: - 歪曲

    private static func applyDistortion(_ image: CIImage, amount: Double) -> CIImage {
        guard abs(amount) > neutralThreshold, let kernel = distortionKernel else { return image }

        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }

        let ratio = clampUnit(amount) / 100
        let k1 = ratio * distortionK1Span
        let k2 = ratio * distortionK2Span
        let center = CIVector(x: extent.midX, y: extent.midY)
        let normScale = 2 / Double(max(extent.width, extent.height))

        let centerPoint = CGPoint(x: extent.midX, y: extent.midY)

        let warped = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in
                LensCorrectionFilter.distortionROI(for: rect, center: centerPoint, normScale: normScale, k1: k1, k2: k2)
            },
            image: image,
            arguments: [center, Float(normScale), Float(k1), Float(k2)]
        )
        guard let warped else { return image }
        // ワープで extent が変わりうるので入力の枠へ戻す。
        return warped.cropped(to: extent)
    }

    /// 歪曲ワープで出力矩形 `rect` が読む入力領域。
    ///
    /// カーネルは出力座標 `p` に対し `center + (p - center) * factor(r²)` をサンプルする
    /// （`factor = 1 + k1 r² + k2 r⁴`、`r` は正規化半径）。変位は中心からの距離に依存するので、
    /// 要求矩形の大きさではなく位置で決まる。`rect` 内の `r²` の範囲で `factor` の最小・最大を求め、
    /// その 2 倍率で中心基準にスケールした矩形の和をとれば全サンプル点を包含する
    /// （サンプル点は `d` と `factor` について双線形なので極値は角 × 倍率の端点）。
    /// 双線形補間の近傍画素ぶん 2px 余裕を持たせる。
    static func distortionROI(
        for rect: CGRect,
        center: CGPoint,
        normScale: Double,
        k1: Double,
        k2: Double
    ) -> CGRect {
        guard !rect.isInfinite, !rect.isNull, !rect.isEmpty else { return rect }

        // rect 内の点の中心からの距離の 2 乗（正規化前）の最小・最大。
        let nearestX = min(max(center.x, rect.minX), rect.maxX)
        let nearestY = min(max(center.y, rect.minY), rect.maxY)
        let minDistance2 = Double((nearestX - center.x) * (nearestX - center.x)
            + (nearestY - center.y) * (nearestY - center.y))
        let farX = max(abs(rect.minX - center.x), abs(rect.maxX - center.x))
        let farY = max(abs(rect.minY - center.y), abs(rect.maxY - center.y))
        let maxDistance2 = Double(farX * farX + farY * farY)

        let scale2 = normScale * normScale
        let lowR2 = minDistance2 * scale2
        let highR2 = maxDistance2 * scale2

        func factor(_ r2: Double) -> Double { 1 + k1 * r2 + k2 * r2 * r2 }

        var candidates = [factor(lowR2), factor(highR2)]
        // r² についての 2 次式なので、頂点が範囲内ならそこも極値候補。
        if k2 != 0 {
            let vertex = -k1 / (2 * k2)
            if vertex > lowR2, vertex < highR2 { candidates.append(factor(vertex)) }
        }
        let minFactor = candidates.min() ?? 1
        let maxFactor = candidates.max() ?? 1

        func scaled(_ f: Double) -> CGRect {
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: f, y: f)
                .translatedBy(x: -center.x, y: -center.y)
            return rect.applying(transform)
        }
        return scaled(minFactor).union(scaled(maxFactor)).insetBy(dx: -2, dy: -2)
    }

    // MARK: - 周辺光量

    private static func applyVignette(_ image: CIImage, amount: Double) -> CIImage {
        guard abs(amount) > neutralThreshold else { return image }

        let filter = CIFilter.vignetteEffect()
        filter.inputImage = image
        let extent = image.extent
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        filter.radius = Float(max(extent.width, extent.height)) * 0.5 * vignetteRadius
        filter.falloff = vignetteFalloff
        // 正の補正量で四隅を持ち上げる（負の intensity）。負の補正量で周辺光量を加える。
        filter.intensity = Float(-clampUnit(amount) / 100 * vignetteIntensitySpan)
        return filter.outputImage ?? image
    }

    // MARK: - 色収差（横）

    private static func applyChromaticAberration(_ image: CIImage, amount: Double) -> CIImage {
        guard abs(amount) > neutralThreshold else { return image }

        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }

        let s = clampUnit(amount) / 100 * chromaticAberrationScaleSpan
        let center = CGPoint(x: extent.midX, y: extent.midY)

        // 縮小した R が extent の縁を覆えるよう、端画素を外へ延長してからスケールする。
        // 延長しないと縁に R が欠けた帯（色付き・アルファ不足）ができる。
        let source = image.clampedToExtent()

        // R を (1 - s)、B を (1 + s) 倍に中心基準でスケールし、G は等倍。
        let red = scaledAboutCenter(source, scale: 1 - s, center: center)
            .applyingFilter("CIColorMatrix", parameters: channelMask(r: 1, g: 0, b: 0))
        let green = source
            .applyingFilter("CIColorMatrix", parameters: channelMask(r: 0, g: 1, b: 0))
        let blue = scaledAboutCenter(source, scale: 1 + s, center: center)
            .applyingFilter("CIColorMatrix", parameters: channelMask(r: 0, g: 0, b: 1))

        let rg = red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
        let rgb = blue.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: rg])
        return rgb.cropped(to: extent)
    }

    /// 単一チャンネルだけを残す `CIColorMatrix` パラメータ。3 層を `CIAdditionCompositing`
    /// （premultiplied 値の単純加算）で合成した結果のアルファがちょうど 1 になるよう、各層の
    /// アルファを 1/3 にする。
    ///
    /// `CIColorMatrix` は非 premultiplied の値で計算し、出力時にアルファを掛け戻す。
    /// アルファ 1/3 だと色も 1/3 倍されて格納されるため、チャンネル係数を 3 倍にしておき、
    /// premultiplied 値が元のチャンネル値そのものになるようにする（合成後 = (R, G, B, 1)）。
    /// 各層のアルファを 1 にすると合成後のアルファが 3 になり、後段フィルタが非 premultiplied 化
    /// する際に色が 1/3 に潰れる。
    private static func channelMask(r: CGFloat, g: CGFloat, b: CGFloat) -> [String: Any] {
        [
            "inputRVector": CIVector(x: r * 3, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g * 3, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b * 3, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1.0 / 3.0)
        ]
    }

    /// 中心を固定してスケールする（`translate(center) * scale * translate(-center)`）。
    private static func scaledAboutCenter(_ image: CIImage, scale: Double, center: CGPoint) -> CIImage {
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
        return image.transformed(by: transform)
    }

    // MARK: - ヘルパー

    private static func clampUnit(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        return min(max(value, -100), 100)
    }

    // MARK: - metallib ロード

    /// カーネルのロード結果。生成コストが高く不変なので一度だけ評価する。
    private static let loaded: (kernel: CIWarpKernel?, failureReason: String?) = loadDistortionKernel()

    /// 歪曲補正カーネル。metallib のロードに失敗した場合は `nil`（歪曲補正はスキップされる）。
    static var distortionKernel: CIWarpKernel? { loaded.kernel }

    /// カーネルのロードに失敗した理由（デバッグ用）。成功時は `nil`。
    static var loadFailureReason: String? { loaded.failureReason }

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
