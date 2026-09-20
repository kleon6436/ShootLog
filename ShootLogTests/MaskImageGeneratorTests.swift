import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
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
        brushEdits: [BrushStroke] = [],
        isInverted: Bool = false,
        density: Double = 100,
        feather: Double = 0
    ) -> MaskLayer {
        MaskLayer(
            id: UUID(),
            name: "test",
            source: source,
            brushEdits: brushEdits,
            isInverted: isInverted,
            density: density,
            feather: feather,
            adjustments: LocalAdjustments()
        )
    }

    private func generate(
        _ layer: MaskLayer,
        baseExtent: CGRect = MaskImageGeneratorTests.extent,
        sourceImage: CIImage? = nil,
        maskRasters: [UUID: CGImage] = [:]
    ) -> CIImage {
        MaskImageGenerator.maskImage(
            for: layer, baseExtent: baseExtent, sourceImage: sourceImage, maskRasters: maskRasters
        )
    }

    /// 指定した明度（0...1）の単色グレースケール `CGImage` を作る（AIマスクのラスタを模す）。
    private func makeGrayscaleCGImage(value: Double, size: Int = 8) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
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
        let mask = generate(makeLayer(source: horizontalGradient))

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
            let mask = generate(makeLayer(source: source))
            #expect(mask.extent == Self.extent)
        }

        // feather を掛けるとガウシアンが extent を広げるが、最後の crop で戻る。
        let feathered = generate(makeLayer(source: horizontalGradient, feather: 100))
        #expect(feathered.extent == Self.extent)

        // 原点が 0 でない extent でも一致すること。
        let offset = CGRect(x: 40, y: -25, width: 80, height: 60)
        let offsetMask = generate(makeLayer(source: horizontalGradient), baseExtent: offset)
        #expect(offsetMask.extent == offset)
    }

    @Test("正規化座標は左上原点で、Core Image の Y 軸へ反転して写される")
    func normalizedCoordinatesUseTopLeftOrigin() {
        let context = makeContext()
        let source = MaskSource.linearGradient(LinearGradientMask(
            start: NormalizedPoint(x: 0.5, y: 0),
            end: NormalizedPoint(x: 0.5, y: 1)
        ))
        let mask = generate(makeLayer(source: source))

        // 始点は画像の上端 ＝ Core Image の y = maxY 側。
        #expect(sample(mask, x: 50, y: 99, context: context) < 0.01)
        #expect(sample(mask, x: 50, y: 0, context: context) > 0.99)

        // 原点が 0 でない extent でも上端＝maxY 側であること。
        // （`height - y*height - origin.y` のように origin.y を引く変換だと、ここで上下がずれる）
        let offset = CGRect(x: 40, y: -25, width: 80, height: 60)
        let offsetMask = generate(makeLayer(source: source), baseExtent: offset)
        #expect(sample(offsetMask, x: 80, y: 34, context: context) < 0.01)
        #expect(sample(offsetMask, x: 80, y: -25, context: context) > 0.99)
    }

    // MARK: - 合成段

    @Test("isInverted で始点と終点の値が入れ替わる")
    func invertedSwapsEndpoints() {
        let context = makeContext()
        let mask = generate(makeLayer(source: horizontalGradient, isInverted: true))

        #expect(sample(mask, x: 0, y: 50, context: context) > 0.99)
        #expect(sample(mask, x: 99, y: 50, context: context) < 0.01)
    }

    @Test("density 50 でマスク値が概ね半分になる")
    func densityScalesMask() {
        let context = makeContext()
        let full = generate(makeLayer(source: horizontalGradient, density: 100))
        let half = generate(makeLayer(source: horizontalGradient, density: 50))

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
        let sharp = generate(makeLayer(source: step))
        let soft = generate(makeLayer(source: step, feather: 100))

        #expect(sample(sharp, x: 48, y: 50, context: context) < 0.01)
        #expect(sample(sharp, x: 52, y: 50, context: context) > 0.99)
        #expect(sample(soft, x: 48, y: 50, context: context) > 0.05)
        #expect(sample(soft, x: 52, y: 50, context: context) < 0.95)
    }

    @Test("合成順は isInverted → density → feather")
    func compositionOrder() {
        let context = makeContext()
        let mask = generate(makeLayer(source: horizontalGradient, isInverted: true, density: 50))

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
        generate(
            makeLayer(source: radialSource(
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
            let mask = generate(makeLayer(source: source))
            #expect(mask.extent == Self.extent)
            for point in [(0, 0), (50, 50), (99, 99), (0, 99)] {
                #expect(sample(mask, x: point.0, y: point.1, context: context) < 0.001)
            }
        }
    }

    // MARK: - 未対応の生成子

    @Test("未対応の生成子・未解決のAIラスタは例外を投げず全面 0 を返す")
    func unsupportedSourcesProduceEmptyMask() {
        let context = makeContext()
        let sources: [MaskSource] = [
            .none,
            // maskRastersに対応するrasterIDが無い場合。§3.2.1の安全側フォールバック
            // （黙って全面1にすると写真全体へ効いてしまう）。
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
            let mask = generate(makeLayer(source: source))
            for point in [(0, 0), (50, 50), (99, 99), (0, 99)] {
                #expect(sample(mask, x: point.0, y: point.1, context: context) < 0.001)
            }
        }
    }

    // MARK: - AIマスク（解決済みラスタ）

    @Test("maskRastersに解決済みラスタがあれば、そのマスク値が反映される")
    func aiMaskUsesResolvedRaster() {
        let context = makeContext()
        let rasterID = UUID()
        // 明度0.75のグレースケールラスタ。ベース空間より小さい8x8のまま渡し、
        // baseExtent(100x100)へ拡大されることも同時に確認する。
        let cgImage = makeGrayscaleCGImage(value: 0.75)
        let reference = AIMaskReference(
            rasterID: rasterID, kind: .foregroundSubject, instanceIndices: [0],
            visionRevision: 1, bakedLongEdge: 8, bakedAt: .now
        )
        let layer = makeLayer(source: .ai(reference))

        let mask = generate(layer, maskRasters: [rasterID: cgImage])

        #expect(mask.extent == Self.extent)
        for point in [(10, 10), (50, 50), (90, 90)] {
            let value = sample(mask, x: point.0, y: point.1, context: context)
            #expect(abs(value - 0.75) < 0.05)
        }
    }

    @Test("AIマスクにdensity/invertが正しく適用される")
    func aiMaskRespectsCompositionOrder() {
        let context = makeContext()
        let rasterID = UUID()
        let cgImage = makeGrayscaleCGImage(value: 0.8)
        let reference = AIMaskReference(
            rasterID: rasterID, kind: .person, instanceIndices: [0],
            visionRevision: 1, bakedLongEdge: 8, bakedAt: .now
        )
        // isInverted: 0.8 -> 0.2、density 50: 0.2 * 0.5 = 0.1
        let layer = makeLayer(source: .ai(reference), isInverted: true, density: 50)

        let mask = generate(layer, maskRasters: [rasterID: cgImage])

        let value = sample(mask, x: 50, y: 50, context: context)
        #expect(abs(value - 0.1) < 0.05)
    }

    @Test("始点と終点が同じ線形グラデーションは全面 0 になる")
    func degenerateGradientProducesEmptyMask() {
        let context = makeContext()
        let source = MaskSource.linearGradient(LinearGradientMask(
            start: NormalizedPoint(x: 0.5, y: 0.5),
            end: NormalizedPoint(x: 0.5, y: 0.5)
        ))
        let mask = generate(makeLayer(source: source))

        #expect(mask.extent == Self.extent)
        #expect(sample(mask, x: 50, y: 50, context: context) < 0.001)
    }

    // MARK: - 輝度レンジ

    /// 生成子はガンマ（sRGB）空間で輝度を索引するため、ソース画像はリニア光として渡す。
    /// ここで逆変換を掛けておくと、生成子側の `CILinearToSRGBToneCurve` を経て
    /// 索引される輝度がちょうど `value`（表示に近い値）になる。
    private func asLinearLight(_ image: CIImage) -> CIImage {
        image.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// ガンマ空間で一様な輝度 `value` になるソース画像。
    private func flatSource(_ value: Double, extent: CGRect = MaskImageGeneratorTests.extent) -> CIImage {
        asLinearLight(CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1)))
            .cropped(to: extent)
    }

    /// ガンマ空間で左端 0 → 右端 1 になるグレースケール。輝度 L はおよそ `(x + 0.5) / 幅`。
    private var luminanceRamp: CIImage {
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: 0, y: 50)
        filter.point1 = CGPoint(x: 100, y: 50)
        filter.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        filter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        return asLinearLight(filter.outputImage ?? CIImage.empty()).cropped(to: Self.extent)
    }

    private func luminanceSource(
        lower: Double,
        upper: Double,
        smoothness: Double = 0
    ) -> MaskSource {
        .luminanceRange(LuminanceRangeMask(lowerBound: lower, upperBound: upper, smoothness: smoothness))
    }

    @Test("一様な輝度は範囲内で選択され、範囲外では選択されない")
    func luminanceRangeSelectsFlatSourceInsideBounds() {
        let context = makeContext()
        let source = flatSource(0.5)

        let inside = generate(makeLayer(source: luminanceSource(lower: 0.4, upper: 0.6)), sourceImage: source)
        let outside = generate(makeLayer(source: luminanceSource(lower: 0.7, upper: 0.9)), sourceImage: source)

        #expect(sample(inside, x: 50, y: 50, context: context) > 0.99)
        #expect(sample(outside, x: 50, y: 50, context: context) < 0.01)
    }

    @Test("輝度グラデーションでは選択範囲に対応する帯だけが立つ")
    func luminanceRangeSelectsBandOnGradient() {
        let context = makeContext()
        let mask = generate(
            makeLayer(source: luminanceSource(lower: 0.3, upper: 0.7)),
            sourceImage: luminanceRamp
        )

        // 帯の内側（L ≒ 0.5）。
        #expect(sample(mask, x: 50, y: 50, context: context) > 0.9)
        // 下限・上限のすぐ内側。境界は LUT の刻み（1/255）ぶん鈍るため余裕を取って標本する。
        #expect(sample(mask, x: 35, y: 50, context: context) > 0.9)
        #expect(sample(mask, x: 65, y: 50, context: context) > 0.9)
        // 帯の外側。
        #expect(sample(mask, x: 25, y: 50, context: context) < 0.1)
        #expect(sample(mask, x: 75, y: 50, context: context) < 0.1)
        #expect(sample(mask, x: 5, y: 50, context: context) < 0.01)
        #expect(sample(mask, x: 95, y: 50, context: context) < 0.01)
    }

    @Test("smoothness が大きいほど境界の遷移が緩やかになる")
    func luminanceRangeSmoothnessSoftensEdge() {
        let context = makeContext()
        func value(at luma: Double, smoothness: Double) -> Double {
            let layer = makeLayer(source: luminanceSource(lower: 0.4, upper: 0.6, smoothness: smoothness))
            return sample(generate(layer, sourceImage: flatSource(luma)), x: 50, y: 50, context: context)
        }

        // 範囲のすぐ外側。急峻なら 0、滑らかなら裾が残る。
        #expect(value(at: 0.65, smoothness: 0) < 0.01)
        #expect(value(at: 0.65, smoothness: 100) > 0.15)

        // 範囲の中心。滑らかにすると頂点も 1 より下がる。
        #expect(value(at: 0.5, smoothness: 0) > 0.99)
        #expect(value(at: 0.5, smoothness: 100) < 0.97)
    }

    @Test("sourceImage が nil の輝度レンジマスクは全面 0 になる")
    func luminanceRangeWithoutSourceImageProducesEmptyMask() {
        let context = makeContext()
        let mask = generate(makeLayer(source: luminanceSource(lower: 0, upper: 1)))

        #expect(mask.extent == Self.extent)
        for point in [(0, 0), (50, 50), (99, 99), (0, 99)] {
            #expect(sample(mask, x: point.0, y: point.1, context: context) < 0.001)
        }
    }

    @Test("退化した輝度レンジは例外を投げず全面 0 相当を返す")
    func degenerateLuminanceRangeProducesEmptyMask() {
        let context = makeContext()
        let sources: [MaskSource] = [
            luminanceSource(lower: 0.9, upper: 0.1),
            luminanceSource(lower: .nan, upper: 1),
            luminanceSource(lower: 0, upper: .nan)
        ]

        for source in sources {
            for luma in [0.05, 0.5, 0.95] {
                let mask = generate(makeLayer(source: source), sourceImage: flatSource(luma))
                #expect(mask.extent == Self.extent)
                #expect(sample(mask, x: 50, y: 50, context: context) < 0.01)
            }
        }

        // smoothness が非有限なら 0 として扱う（範囲自体は生きる）。
        let nanSmoothness = luminanceSource(lower: 0.4, upper: 0.6, smoothness: .nan)
        let mask = generate(makeLayer(source: nanSmoothness), sourceImage: flatSource(0.5))
        #expect(sample(mask, x: 50, y: 50, context: context) > 0.99)
    }

    @Test("輝度レンジマスクの extent は sourceImage より baseExtent が優先される")
    func luminanceRangeMaskExtentMatchesBaseExtent() {
        let context = makeContext()
        // ソースが baseExtent の左下 1/4 しか覆っていない場合。
        let partial = flatSource(0.5, extent: CGRect(x: 0, y: 0, width: 50, height: 50))
        let mask = generate(makeLayer(source: luminanceSource(lower: 0.4, upper: 0.6)), sourceImage: partial)

        #expect(mask.extent == Self.extent)
        #expect(sample(mask, x: 25, y: 25, context: context) > 0.99)
        #expect(sample(mask, x: 75, y: 75, context: context) < 0.001)
    }

    // MARK: - ブラシ編集

    /// 画像中央を水平に横切る半径 5px のストローク。
    private func brushStroke(
        from start: (Double, Double) = (0.2, 0.5),
        to end: (Double, Double) = (0.8, 0.5),
        radius: Double = 0.05,
        opacity: Double = 100,
        isEraser: Bool = false
    ) -> BrushStroke {
        BrushStroke(
            points: [BrushPoint(x: start.0, y: start.1), BrushPoint(x: end.0, y: end.1)],
            radius: radius,
            hardness: 100,
            opacity: opacity,
            isEraser: isEraser
        )
    }

    @Test("source が .none でも brushEdits だけでマスクが立つ")
    func brushOnlyLayerProducesMask() {
        let context = makeContext()
        let mask = generate(makeLayer(source: .none, brushEdits: [brushStroke()]))

        #expect(mask.extent == Self.extent)
        #expect(sample(mask, x: 50, y: 50, context: context) > 0.99)
        #expect(sample(mask, x: 50, y: 80, context: context) < 0.01)
        #expect(sample(mask, x: 5, y: 50, context: context) < 0.01)
    }

    @Test("生成子のベースへブラシを足すと両方の効果が合成される")
    func brushIsAddedOnTopOfGeneratedBase() {
        let context = makeContext()
        let base = generate(makeLayer(source: horizontalGradient))
        let painted = generate(makeLayer(
            source: horizontalGradient,
            brushEdits: [brushStroke(from: (0.1, 0.5), to: (0.2, 0.5))]
        ))

        // ブラシが通った場所はベースに加算されて飽和する（ベース値は 1 より十分小さい）。
        #expect(sample(base, x: 15, y: 50, context: context) < 0.3)
        #expect(sample(painted, x: 15, y: 50, context: context) > 0.99)

        // ブラシから離れた場所はベースのまま。
        for point in [(15, 80), (60, 50), (90, 50)] {
            let expected = sample(base, x: point.0, y: point.1, context: context)
            #expect(abs(sample(painted, x: point.0, y: point.1, context: context) - expected) < 0.02)
        }
    }

    @Test("生成子のベースを消しゴムストロークで削れる")
    func eraserStrokeSubtractsFromGeneratedBase() {
        let context = makeContext()
        // 右端に近いほどベース値が高い。そこを消しゴムで横切る。
        let base = generate(makeLayer(source: horizontalGradient))
        let erased = generate(makeLayer(
            source: horizontalGradient,
            brushEdits: [brushStroke(from: (0.8, 0.5), to: (0.9, 0.5), isEraser: true)]
        ))

        #expect(sample(base, x: 85, y: 50, context: context) > 0.9)
        #expect(sample(erased, x: 85, y: 50, context: context) < 0.01)
        // 消しゴムが通っていない場所はベースのまま。
        let untouched = sample(base, x: 85, y: 80, context: context)
        #expect(abs(sample(erased, x: 85, y: 80, context: context) - untouched) < 0.02)
    }

    @Test("不透明度の低い消しゴムはベースを部分的に削る")
    func partialOpacityEraserReducesGeneratedBase() {
        let context = makeContext()
        let base = generate(makeLayer(source: horizontalGradient))
        let erased = generate(makeLayer(
            source: horizontalGradient,
            brushEdits: [brushStroke(from: (0.8, 0.5), to: (0.9, 0.5), opacity: 40, isEraser: true)]
        ))

        let expected = sample(base, x: 85, y: 50, context: context) - 0.4
        #expect(abs(sample(erased, x: 85, y: 50, context: context) - expected) < 0.03)
    }

    @Test("AIマスクのはみ出しを消しゴムで削れる")
    func eraserStrokeRefinesAIMask() {
        let context = makeContext()
        let rasterID = UUID()
        let reference = AIMaskReference(
            rasterID: rasterID, kind: .foregroundSubject, instanceIndices: [0],
            visionRevision: 1, bakedLongEdge: 8, bakedAt: .now
        )
        let layer = makeLayer(
            source: .ai(reference),
            brushEdits: [brushStroke(from: (0.2, 0.5), to: (0.8, 0.5), isEraser: true)]
        )

        let mask = generate(layer, maskRasters: [rasterID: makeGrayscaleCGImage(value: 1)])

        #expect(sample(mask, x: 50, y: 50, context: context) < 0.01)
        #expect(sample(mask, x: 50, y: 80, context: context) > 0.99)
    }

    @Test("ブラシの合成はクランプ → 反転 → 濃度の順に入る")
    func brushIsCompositedBeforeInvertAndDensity() {
        let context = makeContext()
        let mask = generate(makeLayer(
            source: .none,
            brushEdits: [brushStroke()],
            isInverted: true,
            density: 50
        ))

        // ブラシの芯: 1 → 反転で 0。
        #expect(sample(mask, x: 50, y: 50, context: context) < 0.01)
        // ブラシの外: 0 → 反転で 1 → 濃度 50% で 0.5。
        #expect(abs(sample(mask, x: 50, y: 80, context: context) - 0.5) < 0.02)
    }
}
