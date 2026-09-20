import Foundation
import Testing

@testable import ShootLog

/// マスク編集オーバーレイの座標変換。
///
/// 主基準は「実 UI と同じ入力（`previewImage` の実サイズ）での表示点往復が 1px 以内」。
/// `ImageDevelopmentEngine.applyCrop` の `.integral` 丸めを再現したプレビューサイズを使うことで、
/// 解析的に `cropRect` から表示サイズを再構成する実装との差を検出できるようにしてある。
struct MaskGeometryTests {

    // MARK: - ヘルパー

    /// `ImageDevelopmentEngine` の `applyRotation` → `applyCrop` と同じ計算で、
    /// 実際に画面へ出る `previewImage` の画素サイズを求める（`.integral` 丸めを含む）。
    private func previewPixelSize(basePixelSize: CGSize, rotation: Int, cropRect: CGRect?) -> CGSize {
        let isQuarterTurn = ((rotation % 180) + 180) % 180 != 0
        let rotated = CGSize(
            width: isQuarterTurn ? basePixelSize.height : basePixelSize.width,
            height: isQuarterTurn ? basePixelSize.width : basePixelSize.height
        )
        guard let cropRect, cropRect != CGRect(x: 0, y: 0, width: 1, height: 1),
              cropRect.width > 0, cropRect.height > 0 else {
            return rotated
        }
        let pixelRect = CGRect(
            x: cropRect.minX * rotated.width,
            y: (1 - cropRect.maxY) * rotated.height,
            width: cropRect.width * rotated.width,
            height: cropRect.height * rotated.height
        ).integral
        return pixelRect.size
    }

    /// ベース空間の正規化座標を、`ImageDevelopmentEngine` と同じ**画素**の計算（回転 → `.integral`
    /// 込みの切り抜き）で追跡し、最後に実表示枠へ載せた参照座標。
    /// `MaskGeometry` とは独立にこちらを組み立てることで、回転の向きの誤りや
    /// `cropRect` の解析的再構成に由来するずれを検出できる。
    private func referenceDisplayPoint(
        base: NormalizedPoint,
        basePixelSize: CGSize,
        rotation: Int,
        cropRect: CGRect?,
        imageFrame: CGRect
    ) -> CGPoint {
        let normalized = ((rotation % 360) + 360) % 360
        // ベース画素（左上原点）
        let px = base.x * Double(basePixelSize.width)
        let py = base.y * Double(basePixelSize.height)

        // 時計回り回転後の画素（左上原点）
        let rotatedWidth: Double
        let rotatedHeight: Double
        var rx: Double
        var ry: Double
        switch normalized {
        case 90:
            rotatedWidth = Double(basePixelSize.height)
            rotatedHeight = Double(basePixelSize.width)
            rx = rotatedWidth - py
            ry = px
        case 180:
            rotatedWidth = Double(basePixelSize.width)
            rotatedHeight = Double(basePixelSize.height)
            rx = rotatedWidth - px
            ry = rotatedHeight - py
        case 270:
            rotatedWidth = Double(basePixelSize.height)
            rotatedHeight = Double(basePixelSize.width)
            rx = py
            ry = rotatedHeight - px
        default:
            rotatedWidth = Double(basePixelSize.width)
            rotatedHeight = Double(basePixelSize.height)
            rx = px
            ry = py
        }

        // `applyCrop` は CIImage の左下原点で矩形を組み立てて `.integral` で丸める
        var croppedWidth = rotatedWidth
        var croppedHeight = rotatedHeight
        if let cropRect, cropRect != CGRect(x: 0, y: 0, width: 1, height: 1),
           cropRect.width > 0, cropRect.height > 0 {
            let pixelRect = CGRect(
                x: cropRect.minX * rotatedWidth,
                y: (1 - cropRect.maxY) * rotatedHeight,
                width: cropRect.width * rotatedWidth,
                height: cropRect.height * rotatedHeight
            ).integral
            rx -= Double(pixelRect.minX)
            ry -= rotatedHeight - Double(pixelRect.maxY)
            croppedWidth = Double(pixelRect.width)
            croppedHeight = Double(pixelRect.height)
        }

        return CGPoint(
            x: imageFrame.minX + rx / croppedWidth * imageFrame.width,
            y: imageFrame.minY + ry / croppedHeight * imageFrame.height
        )
    }

    private static let rotations = [0, 90, 180, 270]
    private static let cropRects: [CGRect?] = [nil, CGRect(x: 0.17, y: 0.23, width: 0.55, height: 0.41)]

    // MARK: - 主基準: 実 UI 相当の表示点往復

    @Test("実 previewImage サイズでの表示点往復が 1px 以内（回転 4 種 × トリミング有無）")
    func displayRoundTripIsWithinOnePixel() throws {
        let basePixelSize = CGSize(width: 6016, height: 4014)
        let containerSize = CGSize(width: 1280, height: 803)

        for rotation in Self.rotations {
            for cropRect in Self.cropRects {
                let previewSize = previewPixelSize(
                    basePixelSize: basePixelSize, rotation: rotation, cropRect: cropRect
                )
                let geometry = try #require(
                    MaskGeometry(
                        previewImageSize: previewSize,
                        containerSize: containerSize,
                        rotation: rotation,
                        cropRect: cropRect
                    )
                )

                let frame = geometry.imageFrame
                let samples: [CGPoint] = [
                    CGPoint(x: frame.minX, y: frame.minY),
                    CGPoint(x: frame.maxX, y: frame.minY),
                    CGPoint(x: frame.minX, y: frame.maxY),
                    CGPoint(x: frame.maxX, y: frame.maxY),
                    CGPoint(x: frame.midX, y: frame.midY),
                    CGPoint(x: frame.minX + frame.width * 0.13, y: frame.minY + frame.height * 0.87),
                    // レターボックス外（確定済みクロップ外のハンドル相当）も往復できること
                    CGPoint(x: frame.minX - 40, y: frame.midY + 25)
                ]

                for point in samples {
                    let base = geometry.basePoint(fromDisplay: point)
                    let roundTripped = geometry.displayPoint(fromBase: base)
                    #expect(
                        abs(roundTripped.x - point.x) <= 1.0 && abs(roundTripped.y - point.y) <= 1.0,
                        "rotation=\(rotation) crop=\(String(describing: cropRect)) point=\(point) -> \(roundTripped)"
                    )
                }
            }
        }
    }

    @Test("画素パイプラインを独立に追跡した参照座標と 1px 以内で一致（回転 4 種 × トリミング有無）")
    func displayPointMatchesPixelPipelineReference() throws {
        let basePixelSize = CGSize(width: 6016, height: 4014)
        let containerSize = CGSize(width: 1280, height: 803)
        let basePoints = [
            NormalizedPoint(x: 0, y: 0),
            NormalizedPoint(x: 1, y: 0),
            NormalizedPoint(x: 0, y: 1),
            NormalizedPoint(x: 1, y: 1),
            NormalizedPoint(x: 0.5, y: 0.5),
            NormalizedPoint(x: 0.29, y: 0.64)
        ]

        for rotation in Self.rotations {
            for cropRect in Self.cropRects {
                let previewSize = previewPixelSize(
                    basePixelSize: basePixelSize, rotation: rotation, cropRect: cropRect
                )
                let geometry = try #require(
                    MaskGeometry(
                        previewImageSize: previewSize,
                        containerSize: containerSize,
                        rotation: rotation,
                        cropRect: cropRect
                    )
                )

                for base in basePoints {
                    let actual = geometry.displayPoint(fromBase: base)
                    let expected = referenceDisplayPoint(
                        base: base,
                        basePixelSize: basePixelSize,
                        rotation: rotation,
                        cropRect: cropRect,
                        imageFrame: geometry.imageFrame
                    )
                    #expect(
                        abs(actual.x - expected.x) <= 1.0 && abs(actual.y - expected.y) <= 1.0,
                        "rotation=\(rotation) crop=\(String(describing: cropRect)) base=\(base) actual=\(actual) expected=\(expected)"
                    )
                }
            }
        }
    }

    // MARK: - 補助基準: 解析モデル内部の一貫性

    @Test("ベース正規化 → 表示点 → ベース正規化が 1e-9 以内（解析モデル内部の一貫性のみを見る補助指標）")
    func analyticRoundTripIsExact() throws {
        // この往復は同じ係数を順逆に使うだけなので、`previewImage` の実サイズと解析的再構成の
        // ずれ（`.integral` 丸め）は原理的に検出できない。実 UI のずれは
        // `displayRoundTripIsWithinOnePixel` が担保する。
        let containerSize = CGSize(width: 900, height: 1200)
        let basePoints = [
            NormalizedPoint(x: 0, y: 0),
            NormalizedPoint(x: 1, y: 0),
            NormalizedPoint(x: 0, y: 1),
            NormalizedPoint(x: 1, y: 1),
            NormalizedPoint(x: 0.5, y: 0.5),
            NormalizedPoint(x: 0.31, y: 0.77),
            NormalizedPoint(x: -0.2, y: 1.4)
        ]

        for rotation in Self.rotations {
            for cropRect in Self.cropRects {
                let previewSize = previewPixelSize(
                    basePixelSize: CGSize(width: 4000, height: 3000),
                    rotation: rotation,
                    cropRect: cropRect
                )
                let geometry = try #require(
                    MaskGeometry(
                        previewImageSize: previewSize,
                        containerSize: containerSize,
                        rotation: rotation,
                        cropRect: cropRect
                    )
                )

                for base in basePoints {
                    let roundTripped = geometry.basePoint(
                        fromDisplay: geometry.displayPoint(fromBase: base)
                    )
                    #expect(abs(roundTripped.x - base.x) < 1e-9)
                    #expect(abs(roundTripped.y - base.y) < 1e-9)
                }
            }
        }
    }

    // MARK: - サニティ

    @Test("トリミングなし・回転 0 で表示中心がベース中心へ写る")
    func displayCenterMapsToBaseCenterWithoutRotationOrCrop() throws {
        let geometry = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 4000, height: 3000),
                containerSize: CGSize(width: 800, height: 600),
                rotation: 0,
                cropRect: nil
            )
        )
        let center = CGPoint(x: geometry.containerSize.width / 2, y: geometry.containerSize.height / 2)
        let base = geometry.basePoint(fromDisplay: center)
        #expect(abs(base.x - 0.5) < 1e-12)
        #expect(abs(base.y - 0.5) < 1e-12)
    }

    @Test("90 度回転でベース左上が表示の右上へ写る（回転の向き）")
    func rotationDirectionMatchesEngine() throws {
        let geometry = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 3000, height: 4000),
                containerSize: CGSize(width: 600, height: 800),
                rotation: 90,
                cropRect: nil
            )
        )
        let topLeft = geometry.displayPoint(fromBase: NormalizedPoint(x: 0, y: 0))
        #expect(abs(topLeft.x - geometry.imageFrame.maxX) < 1e-9)
        #expect(abs(topLeft.y - geometry.imageFrame.minY) < 1e-9)
    }

    // MARK: - レターボックス

    @Test("左右レターボックス: 枠外は外挿され、clamped 版だけが 0...1 に収まる")
    func pillarboxOutsidePointExtrapolates() throws {
        // 4:3 のプレビューを縦長コンテナに載せると左右に余白が出る
        let geometry = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 4000, height: 3000),
                containerSize: CGSize(width: 800, height: 900),
                rotation: 0,
                cropRect: nil
            )
        )
        #expect(geometry.imageFrame.minY > 0)
        #expect(abs(geometry.imageFrame.minX) < 1e-9)

        let outside = CGPoint(x: geometry.imageFrame.midX, y: geometry.imageFrame.minY - 30)
        #expect(geometry.containsDisplayPoint(outside) == false)

        let base = geometry.basePoint(fromDisplay: outside)
        #expect(base.y < 0)
        let clamped = geometry.clampedBasePoint(fromDisplay: outside)
        #expect(clamped.y == 0)
        #expect(clamped.x == base.x)
    }

    @Test("上下レターボックス: 枠外は外挿され、clamped 版だけが 0...1 に収まる")
    func letterboxOutsidePointExtrapolates() throws {
        // 4:3 のプレビューを横長コンテナに載せると上下に余白が出る
        let geometry = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 4000, height: 3000),
                containerSize: CGSize(width: 1600, height: 900),
                rotation: 0,
                cropRect: nil
            )
        )
        #expect(geometry.imageFrame.minX > 0)
        #expect(abs(geometry.imageFrame.minY) < 1e-9)

        let outside = CGPoint(x: geometry.imageFrame.maxX + 50, y: geometry.imageFrame.midY)
        #expect(geometry.containsDisplayPoint(outside) == false)

        let base = geometry.basePoint(fromDisplay: outside)
        #expect(base.x > 1)
        let clamped = geometry.clampedBasePoint(fromDisplay: outside)
        #expect(clamped.x == 1)
        #expect(abs(clamped.y - 0.5) < 1e-9)
    }

    // MARK: - 退避条件

    @Test("表示サイズが未確定なら init は nil を返す")
    func initFailsForUnresolvedSizes() {
        #expect(MaskGeometry(
            previewImageSize: .zero, containerSize: CGSize(width: 100, height: 100),
            rotation: 0, cropRect: nil
        ) == nil)
        #expect(MaskGeometry(
            previewImageSize: CGSize(width: 100, height: 100), containerSize: .zero,
            rotation: 0, cropRect: nil
        ) == nil)
    }

    @Test("全面トリミングと不正なトリミングはトリミングなしとして扱う")
    func degenerateCropRectsAreIgnored() throws {
        let fullFrame = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 400, height: 300),
                containerSize: CGSize(width: 800, height: 600),
                rotation: 0,
                cropRect: CGRect(x: 0, y: 0, width: 1, height: 1)
            )
        )
        #expect(fullFrame.cropRect == nil)

        let zeroSized = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 400, height: 300),
                containerSize: CGSize(width: 800, height: 600),
                rotation: 0,
                cropRect: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.5)
            )
        )
        #expect(zeroSized.cropRect == nil)
    }

    @Test("負の回転角と 360 度超も正規化される")
    func rotationIsNormalized() throws {
        let negative = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 300, height: 400),
                containerSize: CGSize(width: 600, height: 800),
                rotation: -90,
                cropRect: nil
            )
        )
        #expect(negative.rotation == 270)

        let overflowing = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 300, height: 400),
                containerSize: CGSize(width: 600, height: 800),
                rotation: 450,
                cropRect: nil
            )
        )
        #expect(overflowing.rotation == 90)
    }

    // MARK: - baseAspectRatio（放射状マスクハンドルのアスペクト比補正、Phase 1b）

    @Test func baseAspectRatioMatchesPreviewWhenNoRotationOrCrop() throws {
        let geometry = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 1600, height: 900),
                containerSize: CGSize(width: 800, height: 600),
                rotation: 0,
                cropRect: nil
            )
        )
        #expect(abs(geometry.baseAspectRatio - (1600.0 / 900.0)) < 1e-9)
    }

    @Test func baseAspectRatioSwapsOnQuarterTurn() throws {
        // previewImageSize は回転・トリミング焼き込み済み（横長 1600x900）。
        // 90度回転していたなら、回転前のベース画像は縦長 900x1600 だったはず。
        let geometry = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 1600, height: 900),
                containerSize: CGSize(width: 800, height: 900),
                rotation: 90,
                cropRect: nil
            )
        )
        #expect(abs(geometry.baseAspectRatio - (900.0 / 1600.0)) < 1e-9)
    }

    @Test func baseAspectRatioUndoesCropToRecoverOriginalRatio() throws {
        // ベース画像は 2000x1000（横長2:1）。中央を正方形に切り抜くと
        // previewImageSize は 1000x1000 になる。baseAspectRatio はこの crop を
        // 逆算して元の 2:1 を復元できなければならない。
        let cropRect = CGRect(x: 0.25, y: 0, width: 0.5, height: 1.0)
        let geometry = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 1000, height: 1000),
                containerSize: CGSize(width: 500, height: 500),
                rotation: 0,
                cropRect: cropRect
            )
        )
        #expect(abs(geometry.baseAspectRatio - 2.0) < 1e-9)
    }

    @Test func baseAspectRatioUndoesCropBeforeRotationSwap() throws {
        // ベース画像 4000x3000（横長 4:3）を90度回転すると 3000x4000。
        // それを幅比0.5・高さ比1.0でクロップすると previewImageSize は 1500x4000。
        // クロップを先に戻す（0.5, 1.0で割る）→ 3000x4000 → 90度スワップ → 4000x3000 → 4:3。
        // 先にスワップしてからcrop比で割ると誤った値（5.33...）になる（Phase 1bレビューで検出）。
        let cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1.0)
        let geometry = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 1500, height: 4000),
                containerSize: CGSize(width: 750, height: 2000),
                rotation: 90,
                cropRect: cropRect
            )
        )
        #expect(abs(geometry.baseAspectRatio - (4000.0 / 3000.0)) < 1e-9)
    }

    @Test func baseAspectRatioUndoesCropBeforeRotationSwapAt270() throws {
        // 270度も90度と同じ「rotation % 180 != 0」分岐を通ることを確認する
        // （ベース4000x3000→270度回転で3000x4000→幅比0.5で切ると1500x4000）。
        let cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1.0)
        let geometry = try #require(
            MaskGeometry(
                previewImageSize: CGSize(width: 1500, height: 4000),
                containerSize: CGSize(width: 750, height: 2000),
                rotation: 270,
                cropRect: cropRect
            )
        )
        #expect(abs(geometry.baseAspectRatio - (4000.0 / 3000.0)) < 1e-9)
    }
}
