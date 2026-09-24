import CoreGraphics
import Foundation
import Testing

@testable import ShootLog

/// 放射状マスクの境界ハンドル計算。`boundaryPoint` と `radiusAndRotation` が互いの逆変換であること。
struct RadialMaskHandleGeometryTests {

    private func mask(radius: Double, aspectRatio: Double, rotationDegrees: Double) -> RadialGradientMask {
        RadialGradientMask(
            center: NormalizedPoint(x: 0.4, y: 0.6),
            radius: radius,
            aspectRatio: aspectRatio,
            rotationDegrees: rotationDegrees,
            falloff: 50
        )
    }

    @Test(arguments: [CGFloat(1.5), 1.0, 0.66])
    func boundaryRoundTripsThroughRadiusAndRotation(baseAspectRatio: CGFloat) throws {
        let original = mask(radius: 0.25, aspectRatio: 2, rotationDegrees: 30)
        let boundary = RadialMaskHandleGeometry.boundaryPoint(original, baseAspectRatio: baseAspectRatio)
        let moved = try #require(RadialMaskHandleGeometry.radiusAndRotation(
            movingBoundaryTo: boundary, center: original.center, baseAspectRatio: baseAspectRatio
        ))
        #expect(abs(moved.radius - original.radius) < 1e-9)
        #expect(abs(moved.rotationDegrees - original.rotationDegrees) < 1e-9)
    }

    @Test func boundaryPointIsOutlineAtAngleZero() {
        let original = mask(radius: 0.2, aspectRatio: 0.5, rotationDegrees: -45)
        let boundary = RadialMaskHandleGeometry.boundaryPoint(original, baseAspectRatio: 1.5)
        let outline = RadialMaskHandleGeometry.outlinePoint(original, at: 0, baseAspectRatio: 1.5)
        #expect(boundary == outline)
    }

    @Test func unrotatedBoundaryOnWideImageScalesXByShortEdge() {
        // 横長 3:2 では短辺基準ピクセル幅が 1.5 なので、正規化 x の変位は radius / 1.5。
        let original = mask(radius: 0.3, aspectRatio: 1, rotationDegrees: 0)
        let boundary = RadialMaskHandleGeometry.boundaryPoint(original, baseAspectRatio: 1.5)
        #expect(abs(boundary.x - (0.4 + 0.3 / 1.5)) < 1e-12)
        #expect(abs(boundary.y - 0.6) < 1e-12)
    }

    @Test func radiusAndRotationIsNilAtCenter() {
        let center = NormalizedPoint(x: 0.5, y: 0.5)
        #expect(RadialMaskHandleGeometry.radiusAndRotation(
            movingBoundaryTo: center, center: center, baseAspectRatio: 1.5
        ) == nil)
    }

    @Test func invalidAspectRatioIsTreatedAsSquare() {
        let original = mask(radius: 0.2, aspectRatio: 1, rotationDegrees: 0)
        let invalid = RadialMaskHandleGeometry.boundaryPoint(original, baseAspectRatio: .nan)
        let square = RadialMaskHandleGeometry.boundaryPoint(original, baseAspectRatio: 1)
        #expect(invalid == square)
    }
}
