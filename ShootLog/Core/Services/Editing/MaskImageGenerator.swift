import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// `MaskLayer` からマスク画像（グレースケール）を生成する。
///
/// 出力は RGB とアルファのすべてにマスク値 m を持つ premultiplied 画像で、
/// そのまま `CIBlendWithMask`（アルファ基準）へ渡せる。
///
/// 合成順は `MaskLayer` のドキュメントに書かれた契約どおり:
/// ```
/// base  = source が生成するグレースケール（none は全面 0）
/// brush = brushEdits を順に適用（Phase 3 まで常に空）
/// m = clamp(base + brush, 0, 1)
/// m = isInverted ? (1 - m) : m
/// m = m * (density / 100)
/// m = feather > 0 ? gaussianBlur(m, radius) : m
/// m = m.cropped(to: baseExtent)
/// ```
///
/// `CISmoothLinearGradient` などのグラデーションフィルタは infinite extent を返すため、
/// 最後の `cropped(to:)` は必須（プラン §1.2 の規約）。これを省くと feather の
/// `CIGaussianBlur` や `CIBlendWithMask` の extent 推論が壊れる。
///
/// `isEnabled` はここでは見ない。無効なレイヤーを飛ばすのは呼び出し側（パイプライン）の責務。
enum MaskImageGenerator {

    /// feather 100 のときのガウシアン半径。extent の長辺に対する比率で持つことで、
    /// プレビュー縮小とフル解像度で効き方が一致する（`LensCorrectionFilter` と同じ流儀）。
    private static let featherRadiusFraction = 0.08

    /// この絶対値以下の feather / density 差は中立とみなす。
    private static let neutralThreshold = 1e-6

    /// 放射状マスクの内外半径が一致すると `CIRadialGradient` の遷移幅が 0 になるため、
    /// falloff 0 でも最低これだけの遷移帯（ピクセル）を残す。エッジのジャギーも同時に抑える。
    private static let minimumRadialTransitionPixels = 0.5

    /// Rec.709 の輝度係数。`ColorGradingFilter` のトーン域マスクと同じ重みを使い、
    /// 「この明るさ」の意味をアプリ内で揃える。
    private static let lumaR = 0.2126
    private static let lumaG = 0.7152
    private static let lumaB = 0.0722

    /// 輝度レンジの `smoothness` 100 における片側遷移幅（輝度 0...1 基準）。
    private static let luminanceSmoothWidthSpan = 0.15

    /// `smoothness` 0 でも遷移幅を 0 にしない下駄。0 除算と 1px のジャギーを同時に避ける。
    private static let minimumLuminanceSmoothWidth = 0.001

    /// 輝度レンジ LUT のサンプル数。`DevelopPipeline.curveSampleCount` と同じ分解能。
    private static let luminanceCurveSampleCount = 256

    /// `CIColorCurves` へ渡す色空間。輝度化の直前でガンマエンコード済みの画像を渡すため、
    /// フィルタ側で再変換させないよう作業空間をそのまま指定する（`DevelopPipeline` と同じ流儀）。
    private static let curveColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 全面 0（完全透明の黒）。infinite extent。
    private static let zeroImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))

    // MARK: - 公開 API

    /// `layer` のマスク画像を `baseExtent` 基準で生成する。戻り値の extent は必ず `baseExtent` と一致する。
    ///
    /// - Parameters:
    ///   - layer: マスクレイヤー。幾何は §1.5 のベース空間（回転・トリミング前）の正規化座標。
    ///   - baseExtent: マスクを載せる画像の extent（ピクセル座標）。
    ///   - sourceImage: 輝度レンジマスクが輝度を読む元画像。幾何ベースの生成子では使わない。
    ///     `nil` かつ輝度レンジマスクの場合は全面 0（画像が無ければ選択しようがない）。
    ///   - maskRasters: AIマスク（`.ai`ソース）が参照する解決済みラスタ（`AIMaskReference.rasterID`
    ///     で引ける）。辞書に無い`rasterID`は全面0として扱う（§3.2.1、写真全体へ誤って
    ///     効かせないための安全側フォールバック）。
    static func maskImage(
        for layer: MaskLayer,
        baseExtent: CGRect,
        sourceImage: CIImage?,
        maskRasters: [UUID: CGImage] = [:]
    ) -> CIImage {
        guard baseExtent.width > 0, baseExtent.height > 0, !baseExtent.isInfinite else {
            return zeroImage.cropped(to: baseExtent)
        }

        var mask = baseImage(for: layer.source, in: baseExtent, sourceImage: sourceImage, maskRasters: maskRasters)
        mask = clampedToUnitInterval(mask)
        if layer.isInverted {
            mask = inverted(mask)
        }
        mask = scaled(mask, by: clampPercent(layer.density) / 100)
        mask = feathered(mask, amount: layer.feather, extent: baseExtent)
        return mask.cropped(to: baseExtent)
    }

    // MARK: - ベース生成子

    /// 実装済みは線形（Phase 1a）・放射状（Phase 1b）・輝度レンジ（Phase 2b）・AI（Phase 2）。
    /// 未知の種別（前方互換、§3.5）は全面 0 を返す。
    private static func baseImage(
        for source: MaskSource,
        in extent: CGRect,
        sourceImage: CIImage?,
        maskRasters: [UUID: CGImage]
    ) -> CIImage {
        switch source {
        case .linearGradient(let gradient):
            return linearGradientImage(gradient, in: extent)
        case .radialGradient(let gradient):
            return radialGradientImage(gradient, in: extent)
        case .luminanceRange(let range):
            return luminanceRangeImage(range, in: extent, sourceImage: sourceImage)
        case .ai(let reference):
            return aiMaskImage(reference, in: extent, maskRasters: maskRasters)
        case .none, .unrecognized:
            return zeroImage
        }
    }

    /// 解決済みラスタ（`bakedLongEdge` px のグレースケール PNG をデコードした `CGImage`）を
    /// `baseExtent` へ拡大して返す。辞書に該当 `rasterID` が無ければ全面 0（§3.2.1）。
    ///
    /// ラスタは `bakedLongEdge`（既定 1024px）で焼き込まれており、実際の現像解像度
    /// （`baseExtent`）より小さいのが通常。`CILanczosScaleTransform` で高品質に拡大する。
    /// グレースケール `CGImage` を `CIImage(cgImage:)` へ通すと A=1・RGB=gray になるため、
    /// 最後に他の生成子と同じ「RGB == A == m」の出力規約へ揃える。
    private static func aiMaskImage(
        _ reference: AIMaskReference,
        in extent: CGRect,
        maskRasters: [UUID: CGImage]
    ) -> CIImage {
        guard let cgImage = maskRasters[reference.rasterID] else { return zeroImage }
        let source = CIImage(cgImage: cgImage)
        guard source.extent.width > 0, source.extent.height > 0 else { return zeroImage }

        let scaleX = extent.width / source.extent.width
        let scaleY = extent.height / source.extent.height
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = source
        filter.scale = Float(scaleY)
        filter.aspectRatio = scaleY > 0 ? Float(scaleX / scaleY) : 1
        guard let scaled = filter.outputImage else { return zeroImage }

        let positioned = scaled.transformed(
            by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y)
        )
        return positioned.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).composited(over: zeroImage)
    }

    private static func linearGradientImage(_ gradient: LinearGradientMask, in extent: CGRect) -> CIImage {
        guard let start = pixelPoint(gradient.start, in: extent),
              let end = pixelPoint(gradient.end, in: extent) else {
            return zeroImage
        }
        // 始点と終点が重なるとグラデーションの向きが定まらない。
        guard hypot(end.x - start.x, end.y - start.y) > neutralThreshold else { return zeroImage }

        let filter = CIFilter.smoothLinearGradient()
        filter.point0 = start
        filter.point1 = end
        filter.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        filter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        return filter.outputImage ?? zeroImage
    }

    /// `CIRadialGradient` は真円しか作れないため、円を生成してから中心固定のアフィン変換で楕円化・回転する。
    ///
    /// 半径は extent の短辺基準でピクセルへ換算する。縦横で別々の基準にすると
    /// `aspectRatio == 1` でも非正方形の画像で真円にならないため。
    private static func radialGradientImage(_ gradient: RadialGradientMask, in extent: CGRect) -> CIImage {
        guard let center = pixelPoint(gradient.center, in: extent),
              gradient.radius.isFinite, gradient.radius > 0,
              gradient.aspectRatio.isFinite, gradient.aspectRatio > 0,
              gradient.rotationDegrees.isFinite else {
            return zeroImage
        }

        let outerRadius = gradient.radius * Double(min(extent.width, extent.height))
        guard outerRadius > minimumRadialTransitionPixels else { return zeroImage }

        // falloff 0 で内外半径がほぼ一致して境界が立ち、100 で中心から外周までの全域が遷移帯になる。
        let falloffRatio = clampPercent(gradient.falloff) / 100
        let innerRadius = min(outerRadius * (1 - falloffRatio), outerRadius - minimumRadialTransitionPixels)

        let filter = CIFilter.radialGradient()
        filter.center = center
        // radius0 <= radius1 を保ち、内側（半径小）を白＝マスク値 1、外側を 0 に固定する。
        filter.radius0 = Float(max(innerRadius, 0))
        filter.radius1 = Float(outerRadius)
        filter.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        filter.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let circle = filter.outputImage else { return zeroImage }

        // 「まず楕円化、次に回転」の順に固定する（回転ハンドルで楕円全体を回す直感的な挙動）。
        // 逆順だと回転軸と楕円の軸がずれ、同じ値でも見た目が変わる。
        // `aspectRatio` は 幅 / 高さ。1 より大きいと横長になる。
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: CGFloat(gradient.rotationDegrees * .pi / 180))
            .scaledBy(x: 1, y: CGFloat(1 / gradient.aspectRatio))
            .translatedBy(x: -center.x, y: -center.y)

        // `CISmoothLinearGradient` と違い `CIRadialGradient` は外周を囲む有限 extent を返す。
        // そのまま後段へ渡すと最後の crop が交差で縮み、feather の `clampedToExtent()` も
        // 外周の値を画面全体へ引き伸ばしてしまうため、全面 0 の無限 extent へ載せ直す。
        return circle.transformed(by: transform).composited(over: zeroImage)
    }

    /// 元画像の輝度を 1 次元カーブへ通してマスク値にする。
    ///
    /// Core Image に `smoothstep` 相当のビルトインフィルタが無いため、カーブは CPU 側で
    /// 256 サンプルの LUT に展開して `CIColorCube` ではなく `CIColorCurves` へ渡す
    /// （`DevelopPipeline.colorCurves` と同じ流儀）。必要なのは 1 次元 LUT なので、
    /// 3D キューブより分解能もメモリ効率も良い。
    ///
    /// 輝度の判定は**ガンマ（sRGB）空間**で行う。現像チェーンのマスクループはリニア光
    /// ブラケット内にあるため、素の成分値で索引すると `lowerBound: 0.6` が表示上の 0.8
    /// 相当になり、スライダーの見えと選択結果が食い違う。そのため輝度化の前に
    /// `CILinearToSRGBToneCurve` を挟み、表示に近い値でレンジを解釈する。
    private static func luminanceRangeImage(
        _ range: LuminanceRangeMask,
        in extent: CGRect,
        sourceImage: CIImage?
    ) -> CIImage {
        guard let sourceImage, range.lowerBound.isFinite, range.upperBound.isFinite else {
            return zeroImage
        }

        let gammaEncoded = sourceImage.cropped(to: extent)
            .applyingFilter("CILinearToSRGBToneCurve")

        // `CIColorMatrix` の input*Vector は出力 1 成分ぶんの「行」なので、3 行とも同じ
        // Rec.709 の重みを置くと R = G = B = 輝度になる。
        let luminance = gammaEncoded.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: lumaR, y: lumaG, z: lumaB, w: 0),
            "inputGVector": CIVector(x: lumaR, y: lumaG, z: lumaB, w: 0),
            "inputBVector": CIVector(x: lumaR, y: lumaG, z: lumaB, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        let curve = luminanceCurve(range, count: luminanceCurveSampleCount)
        var interleaved = [Float](repeating: 0, count: curve.count * 3)
        for index in curve.indices {
            interleaved[index * 3] = curve[index]
            interleaved[index * 3 + 1] = curve[index]
            interleaved[index * 3 + 2] = curve[index]
        }

        let filter = CIFilter.colorCurves()
        filter.inputImage = luminance
        filter.curvesData = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        filter.curvesDomain = CIVector(x: 0, y: 1)
        filter.colorSpace = curveColorSpace
        guard let output = filter.outputImage else { return zeroImage }

        // `CIColorCurves` はアルファを素通しするため、マスク値を全チャンネルへ広げる。
        return output.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).composited(over: zeroImage)
    }

    /// 輝度 0...1 を `count` 等分した各点のマスク値。
    private static func luminanceCurve(_ range: LuminanceRangeMask, count: Int) -> [Float] {
        let sampleCount = max(2, count)
        let lower = clampUnitInterval(range.lowerBound)
        let upper = clampUnitInterval(range.upperBound)
        let width = clampPercent(range.smoothness) / 100 * luminanceSmoothWidthSpan + minimumLuminanceSmoothWidth

        let denominator = Double(sampleCount - 1)
        return (0..<sampleCount).map { index in
            let luma = Double(index) / denominator
            let lowLevel = smoothstep(lower - width, lower + width, luma)
            let highLevel = 1 - smoothstep(upper - width, upper + width, luma)
            return Float(clampUnitInterval(min(lowLevel, highLevel)))
        }
    }

    /// HLSL / GLSL 標準の `smoothstep`。`edge0 >= edge1` では階段関数として振る舞う。
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = clampUnitInterval((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    /// ベース空間の正規化座標（左上原点）を Core Image のピクセル座標（左下原点）へ写す。
    private static func pixelPoint(_ point: NormalizedPoint, in extent: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(
            x: extent.origin.x + point.x * extent.width,
            y: extent.origin.y + (1 - point.y) * extent.height
        )
    }

    // MARK: - 合成段

    private static func clampedToUnitInterval(_ image: CIImage) -> CIImage {
        let filter = CIFilter.colorClamp()
        filter.inputImage = image
        filter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return filter.outputImage ?? image
    }

    /// m -> 1 - m。`CIColorInvert` はアルファを反転しないので `CIColorMatrix` で 4 成分まとめて反転する。
    private static func inverted(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
    }

    private static func scaled(_ image: CIImage, by factor: Double) -> CIImage {
        guard abs(factor - 1) > neutralThreshold else { return image }
        let f = CGFloat(factor)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: f),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    private static func feathered(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let ratio = clampPercent(amount) / 100
        guard ratio > neutralThreshold else { return image }
        let radius = ratio * featherRadiusFraction * Double(max(extent.width, extent.height))
        guard radius > neutralThreshold else { return image }

        // 枠の外は端の値で埋める。そうしないとガウシアンが画像の縁を無条件に 0 へ引っ張る。
        let source = image.cropped(to: extent).clampedToExtent()
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = source
        filter.radius = Float(radius)
        return filter.outputImage ?? image
    }

    // MARK: - ヘルパー

    private static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    private static func clampUnitInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
