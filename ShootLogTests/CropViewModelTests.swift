import CoreGraphics
import Testing

@testable import ShootLog

@MainActor
struct CropViewModelTests {

    // MARK: - displayedImageFrame

    @Test func letterboxesWiderImageInSquareContainer() {
        // 2:1 の画像を 100x100 コンテナへ aspect-fit → 幅 100 / 高さ 50、上下に 25 の余白。
        let frame = CropViewModel.displayedImageFrame(
            imagePixelSize: CGSize(width: 200, height: 100),
            rotation: 0,
            in: CGSize(width: 100, height: 100)
        )
        #expect(frame == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func swapsAspectForQuarterTurn() {
        // 2:1 の画像を 90° 回転 → 見かけ 1:2。100x100 コンテナへ → 幅 50 / 高さ 100、左右に 25 の余白。
        let frame = CropViewModel.displayedImageFrame(
            imagePixelSize: CGSize(width: 200, height: 100),
            rotation: 90,
            in: CGSize(width: 100, height: 100)
        )
        #expect(frame == CGRect(x: 25, y: 0, width: 50, height: 100))
    }

    @Test func halfTurnKeepsAspect() {
        let frame = CropViewModel.displayedImageFrame(
            imagePixelSize: CGSize(width: 200, height: 100),
            rotation: 180,
            in: CGSize(width: 100, height: 100)
        )
        #expect(frame == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func degenerateInputFallsBackToContainer() {
        let container = CGSize(width: 120, height: 80)
        let frame = CropViewModel.displayedImageFrame(
            imagePixelSize: .zero, rotation: 0, in: container
        )
        #expect(frame == CGRect(origin: .zero, size: container))
    }

    // MARK: - applyDrag（画像フレーム基準の正規化）

    @Test func normalizesRelativeToImageFrameNotContainer() {
        let vm = CropViewModel(initialRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        // 画像フレームはコンテナ中央の 100x100（周囲 50 の余白）。
        let imageFrame = CGRect(x: 50, y: 50, width: 100, height: 100)
        // 画像フレームの中央をドラッグ → 画像基準で 0.5。
        vm.applyDrag(corner: .bottomRight, location: CGPoint(x: 100, y: 100), imageFrame: imageFrame)
        #expect(abs(vm.normalizedRect.width - 0.5) < 0.001)
        #expect(abs(vm.normalizedRect.height - 0.5) < 0.001)
    }

    @Test func clampsPointsOutsideImageFrameToEdges() {
        let vm = CropViewModel(initialRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let imageFrame = CGRect(x: 50, y: 50, width: 100, height: 100)
        // レターボックス部分（画像の左上より外）をドラッグ → 0 にクランプ。
        vm.applyDrag(corner: .topLeft, location: CGPoint(x: 10, y: 10), imageFrame: imageFrame)
        #expect(vm.normalizedRect.minX == 0)
        #expect(vm.normalizedRect.minY == 0)
    }

    @Test func zeroSizedImageFrameIsIgnored() {
        let original = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let vm = CropViewModel(initialRect: original)
        vm.applyDrag(corner: .topLeft, location: .zero, imageFrame: .zero)
        #expect(vm.normalizedRect == original)
    }

    // MARK: - pixelRect

    @Test func pixelRectMapsIntoImageFrame() {
        let vm = CropViewModel(initialRect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        let imageFrame = CGRect(x: 40, y: 20, width: 200, height: 100)
        #expect(vm.pixelRect(in: imageFrame) == CGRect(x: 90, y: 70, width: 100, height: 25))
    }
}
