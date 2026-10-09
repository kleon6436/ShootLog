import CoreGraphics
import Testing

@testable import ShootLog

/// FullscreenModeView のズーム/パン計算（`ZoomPanGeometry`）。
struct ZoomPanGeometryTests {

    @Test func isPannableOnlyAboveFitScale() {
        #expect(!ZoomPanGeometry.isPannable(scale: 1.0))
        #expect(!ZoomPanGeometry.isPannable(scale: 0.5))
        #expect(ZoomPanGeometry.isPannable(scale: 1.01))
    }

    @Test func translatedAddsDeltaPerAxis() {
        let moved = ZoomPanGeometry.translated(CGSize(width: 10, height: -5), by: CGSize(width: 3, height: 7))
        #expect(moved == CGSize(width: 13, height: 2))
    }

    @Test func fitDisplayPercentIsFittedWidthOverSourceWidth() {
        let percent = ZoomPanGeometry.fitDisplayPercent(
            sourcePixelSize: CGSize(width: 6000, height: 4000),
            fittedImageSize: CGSize(width: 1500, height: 1000)
        )
        #expect(percent == 25)
    }

    @Test func fitDisplayPercentIsNilWhenSizeUnknown() {
        #expect(ZoomPanGeometry.fitDisplayPercent(
            sourcePixelSize: .zero, fittedImageSize: CGSize(width: 800, height: 600)
        ) == nil)
        #expect(ZoomPanGeometry.fitDisplayPercent(
            sourcePixelSize: CGSize(width: 800, height: 600), fittedImageSize: .zero
        ) == nil)
    }

    @Test func displayPercentScalesFitPercent() {
        #expect(ZoomPanGeometry.displayPercent(scale: 2, fitDisplayPercent: 25) == 50)
        #expect(ZoomPanGeometry.displayPercent(scale: 1.25, fitDisplayPercent: 33) == 41)
    }

    @Test func displayPercentFallsBackToScaleWhenFitUnknown() {
        #expect(ZoomPanGeometry.displayPercent(scale: 1.5, fitDisplayPercent: nil) == 150)
    }

    @Test func clampedOffsetIsZeroAtFitScale() {
        let offset = ZoomPanGeometry.clampedOffset(
            CGSize(width: 100, height: 100),
            scale: 1,
            fittedImageSize: CGSize(width: 800, height: 600),
            viewportSize: CGSize(width: 800, height: 600)
        )
        #expect(offset == .zero)
    }

    @Test func clampedOffsetLimitsToHalfOverflow() {
        let offset = ZoomPanGeometry.clampedOffset(
            CGSize(width: 1000, height: -1000),
            scale: 2,
            fittedImageSize: CGSize(width: 800, height: 600),
            viewportSize: CGSize(width: 800, height: 600)
        )
        #expect(offset == CGSize(width: 400, height: -300))
    }

    @Test func referencePixelSizePrefersOriginalOverDisplayed() {
        // 6000px の原本を 1600px のプロキシで表示中でも、基準は原本サイズ
        let size = ZoomPanGeometry.referencePixelSize(
            originalPixelSize: CGSize(width: 6000, height: 4000),
            displayedPixelSize: CGSize(width: 1600, height: 1067)
        )
        #expect(size == CGSize(width: 6000, height: 4000))
    }

    @Test func referencePixelSizeSwapsForPortraitOrientation() {
        // EXIF の PixelWidth/Height は orientation 適用前。表示画像が縦向きなら入れ替える
        let size = ZoomPanGeometry.referencePixelSize(
            originalPixelSize: CGSize(width: 6000, height: 4000),
            displayedPixelSize: CGSize(width: 512, height: 768)
        )
        #expect(size == CGSize(width: 4000, height: 6000))
    }

    @Test func referencePixelSizeFallsBackToDisplayedWhenUnknownOrSmaller() {
        let displayed = CGSize(width: 3200, height: 2133)
        #expect(ZoomPanGeometry.referencePixelSize(
            originalPixelSize: nil, displayedPixelSize: displayed
        ) == displayed)
        #expect(ZoomPanGeometry.referencePixelSize(
            originalPixelSize: CGSize(width: 1600, height: 1067), displayedPixelSize: displayed
        ) == displayed)
    }

    @Test func referencePixelSizeUsesOriginalBeforeDisplayedArrives() {
        #expect(ZoomPanGeometry.referencePixelSize(
            originalPixelSize: CGSize(width: 6000, height: 4000), displayedPixelSize: .zero
        ) == CGSize(width: 6000, height: 4000))
    }

    @Test func fitPercentUsesOriginalResolution() {
        let source = ZoomPanGeometry.referencePixelSize(
            originalPixelSize: CGSize(width: 6000, height: 4000),
            displayedPixelSize: CGSize(width: 3200, height: 2133)
        )
        let fitted = ZoomPanGeometry.fittedImageSize(
            sourcePixelSize: source, viewportSize: CGSize(width: 1600, height: 1200)
        )
        #expect(ZoomPanGeometry.fitDisplayPercent(sourcePixelSize: source, fittedImageSize: fitted) == 27)
    }
}
