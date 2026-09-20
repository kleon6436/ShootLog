import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import ShootLog

/// `MaskImageGenerator` のテスト（線形グラデーション・放射状グラデーション）。
///
/// マスク値はアルファチャンネルで読む。出力は premultiplied で RGB もマスク値を持つが、
/// premultiplied / straight の解釈差に左右されないのはアルファだけであり、
/// `CIBlendWithMask` が実際に読むのもアルファのため。
struct MaskImageGeneratorTests {

    private static let extent = CGRect(x: 0, y: 0, width: 100, height: 100)

    // MARK: - ヘルパー

    /// 色管理を挟まない CIContext。マスク値をガンマ変換なしの生値で読むために必要。
    private func makeContext() -> CIContext {
        CIContext(options: [.workingColorSpace: NSNull()])
    }

    /// `(x, y)` のピクセル（Core Image 座標・左下原点）のマスク値を読む。
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

    private func makeLayer(
        source: MaskSource,
        isInverted: Bool = false,
        density: Double = 100,
        feather: Double = 0
    ) -> MaskLayer {
        MaskLayer(
            id: UUID(),
            name: "test",
            source: source,
            isInverted: isInverted,
            density: density,
            feather: feather,
            adjustments: LocalAdjustments()
        )
    }

    /// 左端 0 → 右端 1 の水平グラデーション。
    private var horizontalGradient: MaskSource {
        .linearGradient(LinearGradientMask(
            start: NormalizedPoint(x: 0, y: 0.5),
            end: NormalizedPoint(x: 1, y: 0.5)
        ))
    }

    // MARK: - 基本

    @Test("線形グラデーションは始点で 0、終点で 1 になる")
    func linearGradientEndpoints() {
        let context = makeContext()
        let mask = MaskImageGenerator.maskImage(for: makeLayer(source: horizontalGradient), baseExtent: Self.extent)

        #expect(sample(mask, x: 0, y: 50, context: context) < 0.01)
        #expect(sample(mask, x: 99, y: 50, context: context) > 0.99)
        #expect(abs(sample(mask, x: 50, y: 50, context: context) - 0.5) < 0.05)
    }

    @Test("生成されたマスクの extent が baseExtent と一致する（infinite extent が漏れない）")
    func maskExtentMatchesBaseExtent() {
        let sources: [MaskSource] = [
            horizontalGradient,
            .none,
            .radialGradient(RadialGradientMask(
                center: NormalizedPoint(x: 0.5, y: 0.5),
                radius: 0.3,
                aspectRatio: 1,
                rotationDegrees: 0,
                falloff: 0.5
            ))
        ]
        for source in sources {
            let mask = MaskImageGenerator.maskImage(for: makeLayer(source: source), baseExtent: Self.extent)
            #expect(mask.extent == Self.extent)
        }

        // feather を掛けるとガウシアンが extent を広げるが、最後の crop で戻る。
        let feathered = MaskImageGenerator.maskImage(
            for: makeLayer(source: horizontalGradient, feather: 100),
            baseExtent: Self.extent
        )
        #expect(feathered.extent == Self.extent)

        // 原点が 0 でない extent でも一致すること。
        let offset = CGRect(x: 40, y: -25, width: 80, height: 60)
        let offsetMask = MaskImageGenerator.maskImage(for: makeLayer(source: horizontalGradient), baseExtent: offset)
        #expect(offsetMask.extent == offset)
    }

    @Test("正規化座標は左上原点で、Core Image の Y 軸へ反転して写される")
    func normalizedCoordinatesUseTopLeftOrigin() {
        let context = makeContext()
        let source = MaskSource.linearGradient(LinearGradientMask(
            start: NormalizedPoint(x: 0.5, y: 0),
            end: NormalizedPoint(x: 0.5, y: 1)
        ))
        let mask = MaskImageGenerator.maskImage(for: makeLayer(source: source), baseExtent: Self.extent)

        // 始点は画像の上端 ＝ Core Image の y = maxY 側。
        #expect(sample(mask, x: 50, y: 99, context: context) < 0.01)
        #expect(sample(mask, x: 50, y: 0, context: context) > 0.99)

        // 原点が 0 でない extent でも上端＝maxY 側であること。
        // （`height - y*height - origin.y` のように origin.y を引く変換だと、ここで上下がずれる）
        let offset = CGRect(x: 40, y: -25, width: 80, height: 60)
        let offsetMask = MaskImageGenerator.maskImage(for: makeLayer(source: source), baseExtent: offset)
        #expect(sample(offsetMask, x: 80, y: 34, context: context) < 0.01)
        #expect(sample(offsetMask, x: 80, y: -25, context: context) > 0.99)
    }

    // MARK: - 合成段

    @Test("isInverted で始点と終点の値が入れ替わる")
    func invertedSwapsEndpoints() {
        let context = makeContext()
        let mask = MaskImageGenerator.maskImage(
            for: makeLayer(source: horizontalGradient, isInverted: true),
            baseExtent: Self.extent
        )

        #expect(sample(mask, x: 0, y: 50, context: context) > 0.99)
        #expect(sample(mask, x: 99, y: 50, context: context) < 0.01)
    }

    @Test("density 50 でマスク値が概ね半分になる")
    func densityScalesMask() {
        let context = makeContext()
        let full = MaskImageGenerator.maskImage(
            for: makeLayer(source: horizontalGradient, density: 100),
            baseExtent: Self.extent
        )
        let half = MaskImageGenerator.maskImage(
            for: makeLayer(source: horizontalGradient, density: 50),
            baseExtent: Self.extent
        )

        for x in [50, 75, 99] {
            let expected = sample(full, x: x, y: 50, context: context) * 0.5
            #expect(abs(sample(half, x: x, y: 50, context: context) - expected) < 0.02)
        }
    }

    @Test("feather でマスクの境界がぼやける")
    func featherSoftensEdge() {
        let context = makeContext()
        // 中央でほぼ階段状に切り替わるグラデーション。feather 無しなら 48px は 0、52px は 1。
        let step = MaskSource.linearGradient(LinearGradientMask(
            start: NormalizedPoint(x: 0.4995, y: 0.5),
            end: NormalizedPoint(x: 0.5005, y: 0.5)
        ))
        let sharp = MaskImageGenerator.maskImage(for: makeLayer(source: step), baseExtent: Self.extent)
        let soft = MaskImageGenerator.maskImage(for: makeLayer(source: step, feather: 100), baseExtent: Self.extent)

        #expect(sample(sharp, x: 48, y: 50, context: context) < 0.01)
        #expect(sample(sharp, x: 52, y: 50, context: context) > 0.99)
        #expect(sample(soft, x: 48, y: 50, context: context) > 0.05)
        #expect(sample(soft, x: 52, y: 50, context: context) < 0.95)
    }

    @Test("合成順は isInverted → density → feather")
    func compositionOrder() {
        let context = makeContext()
        let mask = MaskImageGenerator.maskImage(
            for: makeLayer(source: horizontalGradient, isInverted: true, density: 50),
            baseExtent: Self.extent
        )

        // 始点のベース値は 0。invert → 1、density → 0.5。
        // 逆順（density → invert）なら 0 * 0.5 = 0 の反転で 1 になる。
        #expect(abs(sample(mask, x: 0, y: 50, context: context) - 0.5) < 0.02)
        #expect(sample(mask, x: 99, y: 50, context: context) < 0.01)
    }

    // MARK: - 放射状グラデーション

    /// 既定は中心・半径 0.4（短辺基準で 40px）・真円・回転なし・falloff 100（中心から外周まで線形）。
    private func radialSource(
        center: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        radius: Double = 0.4,
        aspectRatio: Double = 1,
        rotationDegrees: Double = 0,
        falloff: Double = 100
    ) -> MaskSource {
        .radialGradient(RadialGradientMask(
            center: center,
            radius: radius,
            aspectRatio: aspectRatio,
            rotationDegrees: rotationDegrees,
            falloff: falloff
        ))
    }

    private func radialMask(
        center: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        radius: Double = 0.4,
        aspectRatio: Double = 1,
        rotationDegrees: Double = 0,
        falloff: Double = 100,
        extent: CGRect = MaskImageGeneratorTests.extent
    ) -> CIImage {
        MaskImageGenerator.maskImage(
            for: makeLayer(source: radialSource(
                center: center,
                radius: radius,
                aspectRatio: aspectRatio,
                rotationDegrees: rotationDegrees,
                falloff: falloff
            )),
            baseExtent: extent
        )
    }

    @Test("放射状グラデーションは中心で最大、外周の外で 0 になる")
    func radialGradientPeaksAtCenter() {
        let context = makeContext()
        let mask = radialMask()

        #expect(sample(mask, x: 50, y: 50, context: context) > 0.97)
        #expect(sample(mask, x: 95, y: 50, context: context) < 0.01)
        #expect(sample(mask, x: 50, y: 95, context: context) < 0.01)
    }

    @Test("aspectRatio 1 なら中心から等距離の標本値がほぼ等しい（真円）")
    func radialGradientIsCircularWhenAspectRatioIsOne() {
        let context = makeContext()
        let mask = radialMask()

        // 中心から 20px（半径の 50%）の上下左右。
        let values = [(70, 50), (30, 50), (50, 70), (50, 30)]
            .map { sample(mask, x: $0.0, y: $0.1, context: context) }

        #expect(values.allSatisfy { $0 > 0.4 && $0 < 0.6 })
        if let minValue = values.min(), let maxValue = values.max() {
            #expect(maxValue - minValue < 0.05)
        }
    }

    @Test("aspectRatio != 1 で長軸・短軸の標本値が分かれる（楕円化）")
    func radialGradientAspectRatioProducesEllipse() {
        let context = makeContext()
        // aspectRatio 2 ＝ 幅 / 高さ が 2 の横長楕円。半長軸 40px・半短軸 20px。
        let mask = radialMask(aspectRatio: 2)

        // 中心から 25px の水平方向は楕円の内側、同じ 25px の垂直方向は外側。
        #expect(sample(mask, x: 75, y: 50, context: context) > 0.25)
        #expect(sample(mask, x: 50, y: 75, context: context) < 0.02)
    }

    @Test("rotationDegrees 90 で長軸と短軸の標本値が入れ替わる")
    func radialGradientRotationSwapsAxes() {
        let context = makeContext()
        let upright = radialMask(aspectRatio: 2)
        let rotated = radialMask(aspectRatio: 2, rotationDegrees: 90)

        let uprightLongAxis = sample(upright, x: 75, y: 50, context: context)
        let rotatedLongAxis = sample(rotated, x: 50, y: 75, context: context)

        #expect(abs(rotatedLongAxis - uprightLongAxis) < 0.05)
        #expect(sample(rotated, x: 75, y: 50, context: context) < 0.02)
        #expect(sample(upright, x: 50, y: 75, context: context) < 0.02)
    }

    @Test("falloff が大きいほど外周へ向かう遷移が緩やかになる")
    func radialGradientFalloffSoftensTransition() {
        let context = makeContext()
        // 中心から 30px（半径 40px の 75%）の位置で比較する。
        let sharp = sample(radialMask(falloff: 0), x: 80, y: 50, context: context)
        let medium = sample(radialMask(falloff: 50), x: 80, y: 50, context: context)
        let soft = sample(radialMask(falloff: 100), x: 80, y: 50, context: context)

        #expect(sharp > 0.99)
        #expect(sharp - medium > 0.1)
        #expect(medium - soft > 0.1)

        // falloff によらず中心は最大・外周の外は 0。
        for falloff in [0.0, 50, 100] {
            let mask = radialMask(falloff: falloff)
            #expect(sample(mask, x: 50, y: 50, context: context) > 0.97)
            #expect(sample(mask, x: 95, y: 50, context: context) < 0.01)
        }
    }

    @Test("放射状マスクは原点が 0 でない extent でも正しい位置に置かれる")
    func radialGradientCenterFollowsExtentOrigin() {
        let context = makeContext()
        let extent = CGRect(x: 40, y: -25, width: 200, height: 150)
        // 短辺 150px 基準で半径 30px。中心は (140, 87.5)（正規化 y 0.25 ＝ 上寄り）。
        let mask = radialMask(
            center: NormalizedPoint(x: 0.5, y: 0.25),
            radius: 0.2,
            extent: extent
        )

        #expect(mask.extent == extent)
        #expect(sample(mask, x: 140, y: 87, context: context) > 0.9)
        #expect(sample(mask, x: 140, y: 102, context: context) > 0.3)
        // 上下反転していると、ここ（extent 中心を挟んだ鏡像）が明るくなる。
        #expect(sample(mask, x: 140, y: 12, context: context) < 0.01)
        #expect(sample(mask, x: 100, y: 87, context: context) < 0.01)
    }

    @Test("退化した放射状マスクは例外を投げず全面 0 を返す")
    func degenerateRadialGradientProducesEmptyMask() {
        let context = makeContext()
        let sources: [MaskSource] = [
            radialSource(radius: 0),
            radialSource(radius: -0.5),
            radialSource(radius: .nan),
            radialSource(radius: .infinity),
            radialSource(aspectRatio: 0),
            radialSource(aspectRatio: -1),
            radialSource(aspectRatio: .nan),
            radialSource(rotationDegrees: .nan),
            radialSource(center: NormalizedPoint(x: .nan, y: 0.5))
        ]

        for source in sources {
            let mask = MaskImageGenerator.maskImage(for: makeLayer(source: source), baseExtent: Self.extent)
            #expect(mask.extent == Self.extent)
            for point in [(0, 0), (50, 50), (99, 99), (0, 99)] {
                #expect(sample(mask, x: point.0, y: point.1, context: context) < 0.001)
            }
        }
    }

    // MARK: - 未対応の生成子

    @Test("未対応の生成子は例外を投げず全面 0 を返す")
    func unsupportedSourcesProduceEmptyMask() {
        let context = makeContext()
        let sources: [MaskSource] = [
            .none,
            .ai(AIMaskReference(
                rasterID: UUID(),
                kind: .foregroundSubject,
                instanceIndices: [0],
                visionRevision: 1,
                bakedLongEdge: 1024,
                bakedAt: Date(timeIntervalSince1970: 0)
            )),
            .unrecognized(type: "futureKind", raw: .object(["k": .number(1)]))
        ]

        for source in sources {
            let mask = MaskImageGenerator.maskImage(for: makeLayer(source: source), baseExtent: Self.extent)
            for point in [(0, 0), (50, 50), (99, 99), (0, 99)] {
                #expect(sample(mask, x: point.0, y: point.1, context: context) < 0.001)
            }
        }
    }

    @Test("始点と終点が同じ線形グラデーションは全面 0 になる")
    func degenerateGradientProducesEmptyMask() {
        let context = makeContext()
        let source = MaskSource.linearGradient(LinearGradientMask(
            start: NormalizedPoint(x: 0.5, y: 0.5),
            end: NormalizedPoint(x: 0.5, y: 0.5)
        ))
        let mask = MaskImageGenerator.maskImage(for: makeLayer(source: source), baseExtent: Self.extent)

        #expect(mask.extent == Self.extent)
        #expect(sample(mask, x: 50, y: 50, context: context) < 0.001)
    }
}
