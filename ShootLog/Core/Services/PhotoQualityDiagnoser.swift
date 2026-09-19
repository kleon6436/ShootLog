import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Vision

/// 写真1枚の画質診断スコア。値の意味は `Photo` の `ai*` 永続化フィールドと一致させる。
struct PhotoQualityDiagnosis: Sendable {
    /// 統合美的スコア（0=最低, 1=最高）
    let aestheticsScore: Double?
    /// 書類・スクリーンショット等、Visionが「実用写真」と判定したか
    let isUtility: Bool
    /// 検出顔の最小 faceCaptureQuality（0-1）。顔なしはnil
    let faceQualityScore: Double?
    /// -1(アンダー)〜+1(オーバー)、0=適正
    let exposureBias: Double?
    /// 0-1。大きいほどシャープ
    let sharpnessScore: Double?
    /// 0(中央)〜1(端に寄っている)
    let compositionOffsetScore: Double?
}

/// Vision と Core Image を組み合わせて写真の画質を診断するサービス。
///
/// しきい値・正規化係数は実写真データでの検証前の暫定値であり、
/// ここに閉じ込めることで将来 `DetectLensSmudgeRequest` 等へ差し替えても呼び出し側へ影響しない。
enum PhotoQualityDiagnoser {

    static func diagnose(_ cgImage: CGImage) -> PhotoQualityDiagnosis {
        let vision = visionScores(for: cgImage)
        let image = CIImage(cgImage: cgImage)
        return PhotoQualityDiagnosis(
            aestheticsScore: vision.aestheticsScore,
            isUtility: vision.isUtility,
            faceQualityScore: vision.faceQualityScore,
            exposureBias: exposureBias(for: image),
            sharpnessScore: sharpnessScore(for: image),
            compositionOffsetScore: vision.compositionOffsetScore
        )
    }

    // MARK: - Vision

    private struct VisionScores {
        var aestheticsScore: Double?
        var isUtility = false
        var faceQualityScore: Double?
        var compositionOffsetScore: Double?
    }

    private static func visionScores(for image: CGImage) -> VisionScores {
        var scores = VisionScores()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
        let faceRectanglesRequest = VNDetectFaceRectanglesRequest()
        faceRectanglesRequest.revision = VNDetectFaceRectanglesRequestRevision3
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

        do {
            try handler.perform([aestheticsRequest, faceRectanglesRequest, saliencyRequest])
        } catch {
            return scores
        }

        if let observation = aestheticsRequest.results?.first {
            // overallScore は -1...1 で返る。永続化と閾値テーブルは 0...1 前提のため写像する
            scores.aestheticsScore = (Double(observation.overallScore) + 1) / 2
            scores.isUtility = observation.isUtility
        }

        if let faces = faceRectanglesRequest.results, !faces.isEmpty {
            scores.faceQualityScore = faceQualityScore(for: faces, handler: handler)
        }

        if let saliency = saliencyRequest.results?.first {
            scores.compositionOffsetScore = compositionOffsetScore(for: saliency)
        }

        return scores
    }

    private static func faceQualityScore(
        for faces: [VNFaceObservation],
        handler: VNImageRequestHandler
    ) -> Double? {
        let request = VNDetectFaceCaptureQualityRequest()
        request.revision = VNDetectFaceCaptureQualityRequestRevision3
        request.inputFaceObservations = faces

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let qualities = (request.results ?? []).compactMap { $0.faceCaptureQuality.map(Double.init) }
        // 複数人物では「一番惜しい顔」を指摘したいので最小値を採る
        return qualities.min()
    }

    /// 顕著領域ヒートマップの重み付き重心が、フレーム中心からどれだけ離れているか。
    private static func compositionOffsetScore(for observation: VNSaliencyImageObservation) -> Double? {
        let buffer = observation.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else {
            return nil
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }

        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var totalWeight = 0.0
        var weightedX = 0.0
        var weightedY = 0.0

        for row in 0..<height {
            let rowPointer = (base + row * bytesPerRow).assumingMemoryBound(to: Float.self)
            for column in 0..<width {
                let weight = Double(rowPointer[column])
                guard weight > 0 else { continue }
                totalWeight += weight
                weightedX += weight * (Double(column) + 0.5) / Double(width)
                weightedY += weight * (Double(row) + 0.5) / Double(height)
            }
        }
        guard totalWeight > 0 else { return nil }

        let distance = hypot(weightedX / totalWeight - 0.5, weightedY / totalWeight - 0.5)
        return min(1, distance / maximumCentroidDistance)
    }

    // MARK: - Core Image

    /// 露出・エッジ評価は知覚（ガンマ sRGB）基準で行う。既定のリニア作業空間では
    /// 平均輝度とヒストグラムのビン分布が見た目とずれ、しきい値が意味を持たなくなる。
    private static let analysisContext: CIContext = {
        var options: [CIContextOption: Any] = [:]
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            options[.workingColorSpace] = space
            options[.outputColorSpace] = space
        }
        return CIContext(options: options)
    }()

    private static func exposureBias(for image: CIImage) -> Double? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        guard let mean = averageLuminance(of: image, extent: extent),
              let clipping = clippingRatios(of: image, extent: extent) else {
            return nil
        }

        // 暗側と明側で基準値までのレンジ幅が異なるため、それぞれの幅で割って -1...1 へ揃える
        let deviation = mean >= targetMeanLuminance
            ? (mean - targetMeanLuminance) / (1 - targetMeanLuminance)
            : (mean - targetMeanLuminance) / targetMeanLuminance
        // 端ビンへの張り付きは平均輝度に現れにくいので独立項として加える
        let clippingBias = (clipping.highlight - clipping.shadow) * clippingBiasGain
        return min(1, max(-1, deviation * meanLuminanceWeight + clippingBias * clippingWeight))
    }

    private static func averageLuminance(of image: CIImage, extent: CGRect) -> Double? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = extent
        guard let output = filter.outputImage else { return nil }

        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            analysisContext.render(
                output,
                toBitmap: base,
                rowBytes: 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
        }
        return luminance(red: Double(pixel[0]), green: Double(pixel[1]), blue: Double(pixel[2]))
    }

    /// 黒潰れ・白飛びしている画素の割合（0-1）。
    private static func clippingRatios(
        of image: CIImage,
        extent: CGRect
    ) -> (shadow: Double, highlight: Double)? {
        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = extent
        filter.count = histogramBinCount
        // scale 1.0 で全ビンの合計が 1.0（＝各ビンが画素割合）になる
        filter.scale = 1
        guard let output = filter.outputImage else { return nil }

        var bins = [Float](repeating: 0, count: histogramBinCount * 4)
        bins.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            analysisContext.render(
                output,
                toBitmap: base,
                rowBytes: histogramBinCount * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: histogramBinCount, height: 1),
                format: .RGBAf,
                // ヒストグラムは色ではなく度数なので色変換させない
                colorSpace: nil
            )
        }

        var shadow = 0.0
        var highlight = 0.0
        for offset in 0..<clippingBinCount {
            let low = offset * 4
            let high = (histogramBinCount - 1 - offset) * 4
            shadow += Double(max(bins[low], bins[low + 1], bins[low + 2]))
            highlight += Double(max(bins[high], bins[high + 1], bins[high + 2]))
        }
        return (min(1, shadow), min(1, highlight))
    }

    private static func sharpnessScore(for image: CIImage) -> Double? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }

        // エッジ抽出とCPU読み戻しは画素数に比例するため、評価前に長辺を固定サイズへ縮める
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 0 else { return nil }
        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = image
        scaleFilter.scale = Float(min(1, sharpnessAnalysisLongEdge / longEdge))
        scaleFilter.aspectRatio = 1
        guard let scaled = scaleFilter.outputImage else { return nil }

        let edgesFilter = CIFilter.edges()
        edgesFilter.inputImage = scaled
        edgesFilter.intensity = 1
        guard let edges = edgesFilter.outputImage else { return nil }

        let width = max(1, Int(scaled.extent.width.rounded()))
        let height = max(1, Int(scaled.extent.height.rounded()))
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            analysisContext.render(
                edges,
                toBitmap: base,
                rowBytes: rowBytes,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
        }

        var sum = 0.0
        var sumOfSquares = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = luminance(
                red: Double(pixels[index]) / 255,
                green: Double(pixels[index + 1]) / 255,
                blue: Double(pixels[index + 2]) / 255
            )
            sum += value
            sumOfSquares += value * value
        }

        let count = Double(width * height)
        let mean = sum / count
        let variance = max(0, sumOfSquares / count - mean * mean)
        return min(1, variance.squareRoot() / sharpnessReferenceDeviation)
    }

    private static func luminance(red: Double, green: Double, blue: Double) -> Double {
        red * 0.2126 + green * 0.7152 + blue * 0.0722
    }

    // MARK: - Constants

    /// フレーム中心から四隅までの距離。構図オフセットの正規化に使う
    private static let maximumCentroidDistance = 0.5.squareRoot()
    /// 一般的な写真の平均輝度の目安（ガンマ sRGB）
    private static let targetMeanLuminance = 0.45
    private static let meanLuminanceWeight = 0.7
    private static let clippingWeight = 0.3
    /// クリッピング画素割合を -1...1 相当へ拡大する係数（25%で飽和）
    private static let clippingBiasGain = 4.0
    private static let histogramBinCount = 256
    /// 黒潰れ・白飛びとみなす端ビンの数
    private static let clippingBinCount = 4
    private static let sharpnessAnalysisLongEdge: CGFloat = 640
    /// この標準偏差でエッジ輝度が散っていれば sharpnessScore = 1 とみなす
    private static let sharpnessReferenceDeviation = 0.12
}
