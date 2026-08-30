import CoreImage
import Foundation

/// トーン域マスクを用いてカラーグレーディングを適用する Core Image カーネルのラッパー。
///
/// `ColorGrading.ci.metal` を通常の `default.metallib` として同梱し、ロードに失敗した場合は
/// 入力画像をそのまま返す。現像パイプラインがカーネルの可用性で停止しないためのフォールバックである。
enum ColorGradingFilter {

    private static let colorSpan = 0.15
    private static let lightSpan = 0.15
    private static let saturationScale = 100.0
    private static let lightnessScale = 100.0
    private static let hueSectorDegrees = 60.0
    private static let hueCycleSectors = 6.0
    private static let grayPivot = 0.5
    private static let lumaR = 0.2126
    private static let lumaG = 0.7152
    private static let lumaB = 0.0722

    /// カラーグレーディングを適用した画像を返す。設定が中立、またはカーネル未ロードなら入力をそのまま返す。
    static func graded(_ image: CIImage, settings: ColorBalanceSettings) -> CIImage {
        guard !settings.isNeutral, let kernel = colorKernel else { return image }

        let master = offsets(for: settings.master)
        let shadows = offsets(for: settings.shadows)
        let midtones = offsets(for: settings.midtones)
        let highlights = offsets(for: settings.highlights)

        let graded = kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                master.color, NSNumber(value: master.light),
                shadows.color, NSNumber(value: shadows.light),
                midtones.color, NSNumber(value: midtones.light),
                highlights.color, NSNumber(value: highlights.light)
            ]
        )
        return graded ?? image
    }

    private static func offsets(for component: ColorBalanceComponent) -> (color: CIVector, light: Double) {
        let (red, green, blue) = hueRGB(component.hue)
        let saturation = max(0, component.saturation) / saturationScale
        let redDelta = red - grayPivot
        let greenDelta = green - grayPivot
        let blueDelta = blue - grayPivot
        // 輝度成分を除いて色相移動で明るさが動かないようにする（lightness と直交）。
        let luma = redDelta * lumaR + greenDelta * lumaG + blueDelta * lumaB
        let scale = saturation * colorSpan
        let color = CIVector(
            x: (redDelta - luma) * scale,
            y: (greenDelta - luma) * scale,
            z: (blueDelta - luma) * scale
        )
        let light = component.lightness / lightnessScale * lightSpan
        return (color, light)
    }

    /// HSV（S=1, V=1）の色相を RGB の単位立方体座標へ変換する。
    private static func hueRGB(_ degrees: Double) -> (Double, Double, Double) {
        let sector = (degrees / hueSectorDegrees).truncatingRemainder(dividingBy: hueCycleSectors)
        let normalizedSector = sector < 0 ? sector + hueCycleSectors : sector
        let chroma = 1.0
        let secondary = chroma * (1 - abs(normalizedSector.truncatingRemainder(dividingBy: 2) - 1))

        switch normalizedSector {
        case 0..<1:
            return (chroma, secondary, 0)
        case 1..<2:
            return (secondary, chroma, 0)
        case 2..<3:
            return (0, chroma, secondary)
        case 3..<4:
            return (0, secondary, chroma)
        case 4..<5:
            return (secondary, 0, chroma)
        default:
            return (chroma, 0, secondary)
        }
    }

    // MARK: - metallib ロード

    /// カーネルのロード結果。生成コストが高く不変なので一度だけ評価する。
    private static let loaded: (kernel: CIColorKernel?, failureReason: String?) = loadColorKernel()

    /// カラーグレーディングカーネル。metallib のロードに失敗した場合は `nil`。
    static var colorKernel: CIColorKernel? { loaded.kernel }

    /// カーネルのロードに失敗した理由（デバッグ用）。成功時は `nil`。
    static var loadFailureReason: String? { loaded.failureReason }

    private static func loadColorKernel() -> (kernel: CIColorKernel?, failureReason: String?) {
        let candidates = [Bundle(for: BundleToken.self), Bundle.main]
        guard let url = candidates.lazy
            .compactMap({ $0.url(forResource: "default", withExtension: "metallib") })
            .first else {
            return (nil, "default.metallib が見つからない (searched: \(candidates.map(\.bundlePath)))")
        }
        do {
            let data = try Data(contentsOf: url)
            let kernel = try CIColorKernel(functionName: "colorGrade", fromMetalLibraryData: data)
            return (kernel, nil)
        } catch {
            return (nil, "CIColorKernel 生成失敗 (\(url.lastPathComponent)): \(error)")
        }
    }

    /// `Bundle(for:)` で自ターゲットのバンドルを引くためのアンカー。
    private final class BundleToken {}
}
