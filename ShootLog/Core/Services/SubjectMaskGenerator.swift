import CoreGraphics
import CoreImage
import Foundation
import UniformTypeIdentifiers
import Vision

/// 被写体 / 人物マスクの生成結果。
struct SubjectMaskResult: Sendable {
    /// グレースケール PNG データ（長辺 `longEdge` px）。
    let pngData: Data
    /// 生成された PNG の長辺ピクセル数。元画像が要求解像度より小さい場合は元解像度のまま。
    let longEdge: Int
    /// 選択されたインスタンスのインデックス集合。
    let instanceIndices: [Int]
}

/// Vision framework によるインスタンスマスク生成のプロトコル。
/// `AILabelingClassifying` と同じ注入パターンで、テストはフェイクを差し込む。
///
/// `.person` の誤検出について（512px 合成画像での実測）: `GeneratePersonInstanceMaskRequest` は
/// 人物が写っていない一様色・ノイズ画像に対してもインスタンスを1件返し、
/// そのとき `InstanceMaskObservation.confidence` は**常に 1.0**（一様グレー / 一様白 / ノイズ /
/// 円図形すべてで 1.0）だった。つまり confidence しきい値では誤検出を除去できない。
/// 被覆率も約50%と大きく、面積による判別も成立しない。
/// したがって生成器側では誤検出を弾かず、結果の採否は呼び出し側（UI 層）の責務とする。
/// 対照的に `.foregroundSubject` は同じ一様色・ノイズ画像で `nil` を返し、
/// confidence も内容に応じて変化した（円 0.66 / 人型シルエット 0.84）。
protocol SubjectMaskGenerating: Sendable {
    /// `clickPoint`（Vision の正規化座標系）が指すインスタンス、`nil` なら全インスタンスの
    /// マスクを、長辺 `targetLongEdge` px のグレースケール PNG として生成する。
    /// 対象なし・Vision エラーはすべて `nil` を返す。
    ///
    /// 呼び出し側が守るべき制約:
    /// - **入力画像の最小辺は 512px 以上にする。** 下回ると Vision が
    ///   「Image dimension N is smaller than required minimum 512」を出力し、検出精度が落ちる。
    /// - **`.person` の `nil` は「人物なし」を意味しない。** 実測では人物が写っていない画像
    ///   （一様色・ノイズ）でもインスタンスを1件返すため、戻り値が非 `nil` でも人物がいるとは
    ///   限らない（`SubjectMaskGenerating` の注記を参照）。
    func generateMask(
        for image: CGImage,
        kind: AIMaskKind,
        clickPoint: CGPoint?,
        targetLongEdge: Int
    ) async -> SubjectMaskResult?
}

struct VisionSubjectMaskGenerator: SubjectMaskGenerating {
    static let shared = VisionSubjectMaskGenerator()

    func generateMask(
        for image: CGImage,
        kind: AIMaskKind,
        clickPoint: CGPoint?,
        targetLongEdge: Int
    ) async -> SubjectMaskResult? {
        guard targetLongEdge > 0 else { return nil }

        // Vision の正規化座標は 0...1。範囲外のクリックはどのインスタンスにも当たらない。
        if let clickPoint, !Self.isNormalized(clickPoint) { return nil }

        let handler = ImageRequestHandler(image)

        do {
            let observation: InstanceMaskObservation?
            switch kind {
            case .foregroundSubject:
                observation = try await handler.perform(GenerateForegroundInstanceMaskRequest())
            case .person:
                observation = try await handler.perform(GeneratePersonInstanceMaskRequest())
            }
            guard let observation else { return nil }

            let instances: IndexSet
            if let clickPoint {
                instances = observation.instanceAtPoint(
                    Vision.NormalizedPoint(x: clickPoint.x, y: clickPoint.y)
                )
            } else {
                instances = observation.allInstances
            }
            guard !instances.isEmpty else { return nil }

            let buffer = try observation.generateScaledMask(
                for: instances,
                scaledToImageFrom: handler
            )
            guard let encoded = Self.makeMaskPNG(
                from: CIImage(cvPixelBuffer: buffer),
                targetLongEdge: targetLongEdge
            ) else {
                return nil
            }

            return SubjectMaskResult(
                pngData: encoded.data,
                longEdge: encoded.longEdge,
                instanceIndices: Array(instances)
            )
        } catch {
            return nil
        }
    }
}

extension VisionSubjectMaskGenerator {
    /// マスク画像を長辺 `targetLongEdge` 以下へ収めてグレースケール PNG へ符号化する。
    /// 元画像が既に小さい場合は拡大しない。
    static func makeMaskPNG(
        from image: CIImage,
        targetLongEdge: Int
    ) -> (data: Data, longEdge: Int)? {
        let extent = image.extent
        guard targetLongEdge > 0, !extent.isEmpty, !extent.isInfinite else { return nil }

        let sourceWidth = Int(extent.width.rounded())
        let sourceHeight = Int(extent.height.rounded())
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let sourceLongEdge = max(sourceWidth, sourceHeight)
        let outputWidth: Int
        let outputHeight: Int
        let scaled: CIImage

        if sourceLongEdge <= targetLongEdge {
            outputWidth = sourceWidth
            outputHeight = sourceHeight
            scaled = image
        } else {
            let scale = Double(targetLongEdge) / Double(sourceLongEdge)
            if sourceWidth >= sourceHeight {
                outputWidth = targetLongEdge
                outputHeight = max(1, Int((Double(sourceHeight) * scale).rounded()))
            } else {
                outputHeight = targetLongEdge
                outputWidth = max(1, Int((Double(sourceWidth) * scale).rounded()))
            }
            scaled = image
                .clampedToExtent()
                .applyingFilter(
                    "CILanczosScaleTransform",
                    parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0]
                )
        }

        let renderRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        guard let grayspace = CGColorSpace(name: CGColorSpace.linearGray),
              let cgImage = maskContext.createCGImage(
                  scaled,
                  from: renderRect,
                  format: .L8,
                  colorSpace: grayspace
              ) else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return (mutableData as Data, max(outputWidth, outputHeight))
    }

    private static func isNormalized(_ point: CGPoint) -> Bool {
        (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    /// マスク値はカラーではないので色変換を挟まない。
    private static let maskContext = CIContext(options: [.workingColorSpace: NSNull()])
}
