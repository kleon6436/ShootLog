import Foundation
import Testing

@testable import ShootLog

struct ToneCurveTests {

    // MARK: - ヘルパー

    /// 配列が単調非減少か（浮動小数の評価誤差を許容）。
    private func isNonDecreasing(_ values: [Double], tolerance: Double = 1e-9) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $1 >= $0 - tolerance }
    }

    /// 全要素が 0...1 の範囲内か。
    private func isWithinUnitRange(_ values: [Double], tolerance: Double = 1e-9) -> Bool {
        values.allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
    }

    // MARK: - 恒等カーブ

    @Test func identityCurveIsDetected() {
        #expect(ToneCurve.isIdentity(CurvePoint.identity))
        #expect(ToneCurve.isIdentity([CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]))
    }

    @Test func nonIdentityCurvesAreNotDetected() {
        #expect(!ToneCurve.isIdentity([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]))
        #expect(!ToneCurve.isIdentity([CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]))
        #expect(!ToneCurve.isIdentity([]))
        #expect(!ToneCurve.isIdentity([CurvePoint(x: 0, y: 0)]))
    }

    @Test func identityCurveSamplesToLinearRamp() {
        let samples = ToneCurve.sampled(CurvePoint.identity, count: 256)
        #expect(samples.count == 256)
        for (index, value) in samples.enumerated() {
            let expected = Double(index) / 255
            #expect(abs(value - expected) < 1e-3)
        }
    }

    @Test func explicitIdentityEndpointsSampleToLinearRamp() {
        let points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        let samples = ToneCurve.sampled(points, count: 256)
        #expect(samples.count == 256)
        for (index, value) in samples.enumerated() {
            #expect(abs(value - Double(index) / 255) < 1e-3)
        }
    }

    // MARK: - 単調増加カーブ

    @Test func monotonicCurveStaysMonotonicAndBounded() throws {
        let points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]
        let samples = ToneCurve.sampled(points, count: 256)

        #expect(samples.count == 256)
        #expect(isNonDecreasing(samples))
        #expect(isWithinUnitRange(samples))
        #expect(abs(try #require(samples.first)) < 1e-6)
        #expect(abs(try #require(samples.last) - 1) < 1e-6)
    }

    // MARK: - S 字カーブ

    @Test func sCurveDoesNotOvershoot() {
        let points = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.25, y: 0.15),
            CurvePoint(x: 0.75, y: 0.85),
            CurvePoint(x: 1, y: 1)
        ]
        let samples = ToneCurve.sampled(points, count: 512)

        #expect(samples.count == 512)
        #expect(isNonDecreasing(samples))
        #expect(isWithinUnitRange(samples))
        // クランプ前でも 0...1 に収まっていること（monotone Hermite の非オーバーシュート性）
        #expect(samples.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    // MARK: - 不正な入力

    @Test func reversedAndDuplicateInputProducesMonotonicResult() {
        let points = [
            CurvePoint(x: 1, y: 1),
            CurvePoint(x: 0.5, y: 0.6),
            CurvePoint(x: 0.5, y: 0.4),
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.25, y: 0.3)
        ]
        let samples = ToneCurve.sampled(points, count: 128)

        #expect(samples.count == 128)
        #expect(isNonDecreasing(samples))
        #expect(isWithinUnitRange(samples))
    }

    @Test func outOfRangeControlPointsAreClamped() {
        let points = [
            CurvePoint(x: -0.5, y: -1),
            CurvePoint(x: 0.5, y: 0.5),
            CurvePoint(x: 1.5, y: 2)
        ]
        let samples = ToneCurve.sampled(points, count: 64)

        #expect(samples.count == 64)
        #expect(isNonDecreasing(samples))
        #expect(isWithinUnitRange(samples))
    }

    @Test func singleControlPointFallsBackToLinear() {
        let samples = ToneCurve.sampled([CurvePoint(x: 0.3, y: 0.9)], count: 100)
        #expect(samples.count == 100)
        for (index, value) in samples.enumerated() {
            #expect(abs(value - Double(index) / 99) < 1e-9)
        }
    }

    @Test func emptyInputFallsBackToLinear() {
        let samples = ToneCurve.sampled([], count: 50)
        #expect(samples.count == 50)
        for (index, value) in samples.enumerated() {
            #expect(abs(value - Double(index) / 49) < 1e-9)
        }
    }

    // MARK: - lookupTable

    @Test func lookupTableMatchesSampledInFloatPrecision() {
        let points = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.3, y: 0.5),
            CurvePoint(x: 0.7, y: 0.55),
            CurvePoint(x: 1, y: 1)
        ]
        let doubles = ToneCurve.sampled(points, count: 256)
        let floats = ToneCurve.lookupTable(points, count: 256)

        #expect(floats.count == doubles.count)
        for (lhs, rhs) in zip(floats, doubles) {
            #expect(lhs == Float(rhs))
        }
    }

    // MARK: - サンプル数

    @Test func sampleCountIsExact() {
        for count in [2, 3, 17, 256, 1024] {
            #expect(ToneCurve.sampled(CurvePoint.identity, count: count).count == count)
            let nonIdentity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.8), CurvePoint(x: 1, y: 1)]
            #expect(ToneCurve.sampled(nonIdentity, count: count).count == count)
            #expect(ToneCurve.lookupTable(nonIdentity, count: count).count == count)
        }
    }

    @Test func nonPositiveCountReturnsEmpty() {
        #expect(ToneCurve.sampled(CurvePoint.identity, count: 0).isEmpty)
        #expect(ToneCurve.sampled(CurvePoint.identity, count: -5).isEmpty)
    }
}
