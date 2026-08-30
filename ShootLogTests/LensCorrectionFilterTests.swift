import CoreImage
import Testing
@testable import ShootLog

/// レンズ補正フィルタのテスト。
///
/// Phase 5-1 は Metal CIKernel のビルド疎通（`-fcikernel` フラグ + metallib のバンドル同梱 +
/// テストバンドルからの `Bundle(for:)` 解決）が成立していることの確認に絞る。
struct LensCorrectionFilterTests {

    @Test func distortionKernelLoadsFromMetallib() {
        #expect(
            LensCorrectionFilter.distortionKernel != nil,
            "\(LensCorrectionFilter.loadFailureReason ?? "理由不明")"
        )
    }

    @Test func applyIsIdentityAtPhase5_1() {
        let source = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let result = LensCorrectionFilter.apply(.neutral, to: source)
        #expect(result.extent == source.extent)
    }
}
