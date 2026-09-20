import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import ShootLog

/// `BrushMaskRasterizer` のテスト。
///
/// 出力は符号付き（-1...1）のマスク寄与ぶんで、消しゴムは負値になる。
/// `MaskImageGenerator` と同じくアルファチャンネルで読む。
struct BrushMaskRasterizerTests {

    private static let extent = CGRect(x: 0, y: 0, width: 200, height: 200)

    // MARK: - ヘルパー

    private func makeContext() -> CIContext {
        CIContext(options: [.workingColorSpace: NSNull()])
    }

    /// `(x, y)`（Core Image 座標・左下原点）のマスク寄与を読む。
    private func sample(_ image: CIImage, x: Int, y: Int, context: CIContext) -> Double {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &pixel,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
        return Double(pixel[3])
    }

    /// 相対座標（左上原点・0...1）を標本して値を読む。解像度をまたいだ比較に使う。
    private func sample(
        _ image: CIImage,
        relativeX: Double,
        relativeY: Double,
        extent: CGRect,
        context: CIContext
    ) -> Double {
        let x = Int((extent.origin.x + relativeX * extent.width).rounded(.down))
        let y = Int((extent.origin.y + (1 - relativeY) * extent.height).rounded(.down))
        return sample(image, x: x, y: y, context: context)
    }

    private func stroke(
        points: [(Double, Double)],
        radius: Double = 0.05,
        hardness: Double = 100,
        opacity: Double = 100,
        isEraser: Bool = false
    ) -> BrushStroke {
        BrushStroke(
            points: points.map { BrushPoint(x: $0.0, y: $0.1) },
            radius: radius,
            hardness: hardness,
            opacity: opacity,
            isEraser: isEraser
        )
    }

    /// 画像中央を水平に横切るストローク。
    private func horizontalStroke(
        radius: Double = 0.05,
        hardness: Double = 100,
        opacity: Double = 100,
        isEraser: Bool = false
    ) -> BrushStroke {
        stroke(
            points: [(0.2, 0.5), (0.8, 0.5)],
            radius: radius,
            hardness: hardness,
            opacity: opacity,
            isEraser: isEraser
        )
    }

    private func rasterize(
        _ strokes: [BrushStroke],
        baseExtent: CGRect = BrushMaskRasterizerTests.extent
    ) -> CIImage? {
        BrushMaskRasterizer.rasterize(strokes, baseExtent: baseExtent)
    }

    // MARK: - 基本

    @Test("ストロークの通過点は高く、離れた場所は 0 になる")
    func strokePaintsAlongItsPoints() throws {
        let context = makeContext()
        let image = try #require(rasterize([horizontalStroke()]))

        // 通過点（相対 y 0.5 ＝ Core Image の y 100）。
        #expect(sample(image, x: 40, y: 100, context: context) > 0.99)
        #expect(sample(image, x: 100, y: 100, context: context) > 0.99)
        #expect(sample(image, x: 160, y: 100, context: context) > 0.99)

        // ストロークの外側。半径 0.05 ＝ 10px なので、20px 離れれば 0。
        #expect(sample(image, x: 100, y: 130, context: context) < 0.01)
        #expect(sample(image, x: 100, y: 70, context: context) < 0.01)
        #expect(sample(image, x: 10, y: 100, context: context) < 0.01)
        #expect(sample(image, x: 190, y: 100, context: context) < 0.01)
    }

    @Test("正規化座標は左上原点で、Core Image の Y 軸へ反転して写される")
    func normalizedCoordinatesUseTopLeftOrigin() throws {
        let context = makeContext()
        // 上から 1/4 の位置を横切るストローク。
        let image = try #require(rasterize([stroke(points: [(0.2, 0.25), (0.8, 0.25)])]))

        #expect(sample(image, x: 100, y: 150, context: context) > 0.99)
        // 上下が反転していると、ここ（中央を挟んだ鏡像）が立つ。
        #expect(sample(image, x: 100, y: 50, context: context) < 0.01)
    }

    @Test("原点が 0 でない extent でもストロークが正しい位置に置かれる")
    func strokeFollowsExtentOrigin() throws {
        let context = makeContext()
        let extent = CGRect(x: 40, y: -25, width: 200, height: 100)
        let image = try #require(rasterize([horizontalStroke()], baseExtent: extent))

        // 短辺 100px 基準で半径 5px。相対 (0.5, 0.5) は (140, 25)。
        #expect(sample(image, x: 140, y: 25, context: context) > 0.99)
        #expect(sample(image, x: 140, y: 60, context: context) < 0.01)
        #expect(sample(image, x: 60, y: 25, context: context) < 0.01)
    }

    // MARK: - 解像度非依存

    @Test("同一ストロークは解像度によらず同じ相対位置で同じ値になる")
    func rasterizationIsResolutionIndependent() throws {
        let context = makeContext()
        let strokes = [
            horizontalStroke(radius: 0.08, hardness: 40, opacity: 80),
            stroke(points: [(0.5, 0.2), (0.5, 0.8)], radius: 0.05, hardness: 90)
        ]
        let smallExtent = CGRect(x: 0, y: 0, width: 800, height: 800)
        let largeExtent = CGRect(x: 0, y: 0, width: 3200, height: 3200)

        let small = try #require(rasterize(strokes, baseExtent: smallExtent))
        let large = try #require(rasterize(strokes, baseExtent: largeExtent))

        let probes: [(Double, Double)] = [
            (0.5, 0.5),     // 2 本の交点
            (0.3, 0.5),     // 水平ストロークの芯
            (0.5, 0.3),     // 垂直ストロークの芯
            (0.3, 0.535),   // 水平ストロークの遷移帯
            (0.3, 0.6),     // 水平ストロークの外
            (0.1, 0.1)      // どちらからも遠い
        ]
        for probe in probes {
            let smallValue = sample(small, relativeX: probe.0, relativeY: probe.1, extent: smallExtent, context: context)
            let largeValue = sample(large, relativeX: probe.0, relativeY: probe.1, extent: largeExtent, context: context)
            #expect(abs(smallValue - largeValue) < 0.02, "probe \(probe): \(smallValue) vs \(largeValue)")
        }
    }

    // MARK: - 消しゴム

    @Test("消しゴムストロークは先に描いたストロークを減算する")
    func eraserSubtractsPreviousStroke() throws {
        let context = makeContext()
        let paint = horizontalStroke()
        // 中央付近だけを縦に横切る消しゴム。
        let eraser = stroke(points: [(0.5, 0.3), (0.5, 0.7)], isEraser: true)

        let painted = try #require(rasterize([paint]))
        let erased = try #require(rasterize([paint, eraser]))

        #expect(sample(painted, x: 100, y: 100, context: context) > 0.99)
        #expect(sample(erased, x: 100, y: 100, context: context) < 0.01)
        // 消しゴムが通っていない場所は残る。
        #expect(sample(erased, x: 50, y: 100, context: context) > 0.99)
    }

    @Test("ベースが無い場所への消しゴムは負値になる（生成子のベースを削るため）")
    func eraserAloneProducesNegativeValues() throws {
        let context = makeContext()
        let image = try #require(rasterize([horizontalStroke(isEraser: true)]))

        #expect(sample(image, x: 100, y: 100, context: context) < -0.99)
        #expect(sample(image, x: 100, y: 140, context: context) > -0.01)
    }

    @Test("不透明度の低い消しゴムは部分的にだけ減算する")
    func partialOpacityEraserSubtractsPartially() throws {
        let context = makeContext()
        let paint = horizontalStroke()
        let eraser = stroke(points: [(0.5, 0.3), (0.5, 0.7)], opacity: 40, isEraser: true)

        let image = try #require(rasterize([paint, eraser]))

        #expect(abs(sample(image, x: 100, y: 100, context: context) - 0.6) < 0.02)
    }

    // MARK: - ブラシ設定

    @Test("hardness が高いほど境界の遷移が急峻になる")
    func hardnessSharpensEdge() throws {
        let context = makeContext()
        // 半径 0.15 ＝ 30px。芯から 22px（半径の 73%）の位置で比較する。
        let hard = try #require(rasterize([horizontalStroke(radius: 0.15, hardness: 100)]))
        let medium = try #require(rasterize([horizontalStroke(radius: 0.15, hardness: 50)]))
        let soft = try #require(rasterize([horizontalStroke(radius: 0.15, hardness: 0)]))

        let hardValue = sample(hard, x: 100, y: 122, context: context)
        let mediumValue = sample(medium, x: 100, y: 122, context: context)
        let softValue = sample(soft, x: 100, y: 122, context: context)

        #expect(hardValue > 0.99)
        #expect(hardValue - mediumValue > 0.1)
        #expect(mediumValue - softValue > 0.1)

        // hardness によらず芯はほぼ最大・半径の外は 0。柔らかいブラシは芯が無く
        // スタンプの山谷が max 合成に残るため、背骨でもわずかに 1 を下回る。
        for image in [hard, medium, soft] {
            #expect(sample(image, x: 100, y: 100, context: context) > 0.97)
            #expect(sample(image, x: 100, y: 135, context: context) < 0.01)
        }
    }

    @Test("opacity が低いほどマスク値が薄い")
    func opacityScalesStrokeValue() throws {
        let context = makeContext()
        let full = try #require(rasterize([horizontalStroke(opacity: 100)]))
        let half = try #require(rasterize([horizontalStroke(opacity: 50)]))
        let faint = try #require(rasterize([horizontalStroke(opacity: 20)]))

        #expect(sample(full, x: 100, y: 100, context: context) > 0.99)
        #expect(abs(sample(half, x: 100, y: 100, context: context) - 0.5) < 0.02)
        #expect(abs(sample(faint, x: 100, y: 100, context: context) - 0.2) < 0.02)
    }

    @Test("1 本のストローク内で重ね塗りしても濃度は opacity を超えない")
    func overlappingStampsWithinOneStrokeDoNotAccumulate() throws {
        let context = makeContext()
        // 往復して同じ場所を 2 度通るストローク。
        let backAndForth = stroke(
            points: [(0.3, 0.5), (0.7, 0.5), (0.3, 0.5)],
            opacity: 50
        )
        let image = try #require(rasterize([backAndForth]))

        #expect(abs(sample(image, x: 100, y: 100, context: context) - 0.5) < 0.02)
    }

    @Test("別のストロークどうしは加算される")
    func separateStrokesAccumulate() throws {
        let context = makeContext()
        let first = horizontalStroke(opacity: 40)
        let image = try #require(rasterize([first, first]))

        #expect(abs(sample(image, x: 100, y: 100, context: context) - 0.8) < 0.03)
    }

    // MARK: - 退化した入力

    @Test("空のストローク列では nil を返す")
    func emptyStrokesProduceNil() {
        #expect(rasterize([]) == nil)
        #expect(rasterize([stroke(points: [])]) == nil)
    }

    @Test("退化したストロークは例外を投げず nil か無害な結果になる")
    func degenerateStrokesAreHarmless() {
        let context = makeContext()
        let degenerate: [BrushStroke] = [
            stroke(points: [(0.5, 0.5)], radius: 0),
            stroke(points: [(0.5, 0.5)], radius: 0.0001),   // 1px 未満
            stroke(points: [(0.5, 0.5)], radius: -0.2),
            stroke(points: [(0.5, 0.5)], radius: .nan),
            stroke(points: [(0.5, 0.5)], radius: .infinity),
            stroke(points: [(0.5, 0.5)], hardness: .nan),
            stroke(points: [(0.5, 0.5)], opacity: 0),
            stroke(points: [(0.5, 0.5)], opacity: .nan),
            stroke(points: [(.nan, 0.5), (0.5, .infinity)]),
            stroke(points: [(5, 5), (6, 6)])                // キャンバスの外
        ]

        for item in degenerate {
            if let image = rasterize([item]) {
                #expect(abs(sample(image, x: 100, y: 100, context: context)) < 0.01)
            }
        }

        // 退化した extent。
        #expect(rasterize([horizontalStroke()], baseExtent: .zero) == nil)
        #expect(rasterize([horizontalStroke()], baseExtent: .infinite) == nil)
    }

    @Test("半径 1px 程度の極小ストロークでもクラッシュしない")
    func tinyRadiusIsRasterizedWithoutCrashing() throws {
        let context = makeContext()
        // 半径 0.006 ＝ 1.2px。
        let image = try #require(rasterize([horizontalStroke(radius: 0.006)]))

        #expect(sample(image, x: 100, y: 100, context: context) > 0.5)
        #expect(sample(image, x: 100, y: 110, context: context) < 0.01)
    }

    @Test("出力の extent はストロークを覆う範囲に収まり、baseExtent を超えない")
    func outputExtentStaysInsideBaseExtent() throws {
        let image = try #require(rasterize([horizontalStroke()]))

        #expect(Self.extent.contains(image.extent))
        // 半径 10px ＋ 遷移帯を含む水平ストローク。縦方向は画像全体には広がらない。
        #expect(image.extent.height < 40)
    }
}
