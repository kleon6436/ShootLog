import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing

@testable import ShootLog

/// `VisionSubjectMaskGenerator` のテスト。
///
/// Vision の推論結果そのもの（どの画素が被写体か）は学習済みモデル依存で、合成画像に対する
/// 検出可否を保証できない。そのため「検出できたはず」という前提の assert は置かず、
/// 決定的に検証できる符号化・スケーリング・入力バリデーションを主に検証する。
struct SubjectMaskGeneratorTests {

    // MARK: - ヘルパー

    private func makeCIImage(width: Int, height: Int) -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// 白背景に黒い矩形を1つ置いた合成画像。
    private func makeShapeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        context.fillEllipse(in: CGRect(
            x: Double(width) * 0.3,
            y: Double(height) * 0.3,
            width: Double(width) * 0.4,
            height: Double(height) * 0.4
        ))
        return try #require(context.makeImage())
    }

    /// 一様色の画像。被写体が存在しない入力として使う。
    private func makeFlatImage(width: Int, height: Int, gray: Double) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func decodedSize(of pngData: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(pngData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    // MARK: - 符号化・スケーリング

    @Test("targetLongEdge が元画像より大きいとき拡大しない")
    func doesNotUpscale() throws {
        let encoded = try #require(VisionSubjectMaskGenerator.makeMaskPNG(
            from: makeCIImage(width: 100, height: 50),
            targetLongEdge: 512
        ))

        #expect(encoded.longEdge == 100)
        let size = try decodedSize(of: encoded.data)
        #expect(size.width == 100)
        #expect(size.height == 50)
    }

    @Test("targetLongEdge が元画像より小さいとき長辺が targetLongEdge へ縮む")
    func downscalesToTargetLongEdge() throws {
        let encoded = try #require(VisionSubjectMaskGenerator.makeMaskPNG(
            from: makeCIImage(width: 800, height: 400),
            targetLongEdge: 200
        ))

        #expect(encoded.longEdge == 200)
        let size = try decodedSize(of: encoded.data)
        #expect(size.width == 200)
        #expect(size.height == 100)
    }

    @Test("縦長画像では高さが targetLongEdge になる")
    func downscalesPortraitImage() throws {
        let encoded = try #require(VisionSubjectMaskGenerator.makeMaskPNG(
            from: makeCIImage(width: 300, height: 900),
            targetLongEdge: 300
        ))

        #expect(encoded.longEdge == 300)
        let size = try decodedSize(of: encoded.data)
        #expect(size.width == 100)
        #expect(size.height == 300)
    }

    @Test("出力がデコード可能な PNG であること")
    func producesValidPNG() throws {
        let encoded = try #require(VisionSubjectMaskGenerator.makeMaskPNG(
            from: makeCIImage(width: 64, height: 64),
            targetLongEdge: 64
        ))

        let source = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        _ = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("targetLongEdge が 0 以下なら符号化しない")
    func rejectsNonPositiveTargetLongEdge() {
        #expect(VisionSubjectMaskGenerator.makeMaskPNG(
            from: makeCIImage(width: 64, height: 64),
            targetLongEdge: 0
        ) == nil)
    }

    @Test("extent を持たない画像は符号化しない")
    func rejectsInfiniteExtent() {
        let infinite = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
        #expect(VisionSubjectMaskGenerator.makeMaskPNG(
            from: infinite,
            targetLongEdge: 512
        ) == nil)
    }

    // MARK: - 入力バリデーション

    @Test("targetLongEdge が 0 以下ならマスクを生成しない")
    func generateRejectsNonPositiveTargetLongEdge() async throws {
        let image = try makeShapeImage(width: 128, height: 128)
        let result = await VisionSubjectMaskGenerator.shared.generateMask(
            for: image,
            kind: .foregroundSubject,
            clickPoint: nil,
            targetLongEdge: 0
        )
        #expect(result == nil)
    }

    @Test("正規化範囲外のクリック座標ではマスクを生成しない")
    func generateRejectsOutOfRangeClickPoint() async throws {
        let image = try makeShapeImage(width: 256, height: 256)
        let result = await VisionSubjectMaskGenerator.shared.generateMask(
            for: image,
            kind: .foregroundSubject,
            clickPoint: CGPoint(x: 1.8, y: -0.4),
            targetLongEdge: 512
        )
        #expect(result == nil)
    }

    // MARK: - Vision 推論（モデル依存）

    @Test("一様色の画像では被写体マスクを生成しない")
    func returnsNilForFlatImage() async throws {
        let white = try makeFlatImage(width: 256, height: 256, gray: 1)
        let whiteResult = await VisionSubjectMaskGenerator.shared.generateMask(
            for: white,
            kind: .foregroundSubject,
            clickPoint: nil,
            targetLongEdge: 512
        )
        #expect(whiteResult == nil)

        let black = try makeFlatImage(width: 256, height: 256, gray: 0)
        let blackResult = await VisionSubjectMaskGenerator.shared.generateMask(
            for: black,
            kind: .foregroundSubject,
            clickPoint: nil,
            targetLongEdge: 512
        )
        #expect(blackResult == nil)
    }

    /// `GeneratePersonInstanceMaskRequest` は人物が写っていない一様色の画像に対しても
    /// インスタンスを1件返し、被覆率約50%のマスクを作る（512px 入力で実測）。
    /// このとき `InstanceMaskObservation.confidence` は 1.0 なので、confidence でも面積でも
    /// 誤検出を除去できない。被写体リクエストと違い「空の IndexSet」でも不検出を判定できないため、
    /// 生成器側では誤検出を弾かず、結果の妥当性判断は呼び出し側（UI 層）の責務とする。
    /// ここでは人物経路が例外なく完走し、結果が不変条件を満たすことだけを検証する。
    @Test("人物マスク経路が不変条件を満たす結果を返す")
    func personKindProducesWellFormedResult() async throws {
        let image = try makeFlatImage(width: 512, height: 512, gray: 0.5)
        guard let result = await VisionSubjectMaskGenerator.shared.generateMask(
            for: image,
            kind: .person,
            clickPoint: nil,
            targetLongEdge: 256
        ) else {
            return
        }

        #expect(!result.instanceIndices.isEmpty)
        #expect(result.longEdge == 256)
        let size = try decodedSize(of: result.pngData)
        #expect(max(size.width, size.height) == 256)
    }

    /// 合成図形が Vision に被写体として検出されるかはモデル依存なので `nil` でも失敗にしない。
    /// 検出できた場合だけ、結果の不変条件（PNG の妥当性・解像度・インスタンス非空）を検証する。
    @Test("被写体が検出された場合は結果が不変条件を満たす")
    func shapeMaskSatisfiesInvariantsWhenDetected() async throws {
        let image = try makeShapeImage(width: 512, height: 512)
        guard let result = await VisionSubjectMaskGenerator.shared.generateMask(
            for: image,
            kind: .foregroundSubject,
            clickPoint: nil,
            targetLongEdge: 256
        ) else {
            return
        }

        #expect(!result.instanceIndices.isEmpty)
        #expect(result.longEdge == 256)
        let size = try decodedSize(of: result.pngData)
        #expect(max(size.width, size.height) == 256)
    }
}
