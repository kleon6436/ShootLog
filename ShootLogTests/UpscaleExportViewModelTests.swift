import CoreGraphics
import Testing

@testable import ShootLog

@MainActor
struct UpscaleExportViewModelTests {

    @Test func initialStateIsAIQuadruple() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: nil)
        #expect(viewModel.engineKind == .aiSuperResolution)
        #expect(viewModel.scaleFactor == .quadruple)
    }

    @Test func switchingToAIEngineForcesQuadrupleScale() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: nil)

        viewModel.engineKind = .traditional
        viewModel.scaleFactor = .double
        #expect(viewModel.scaleFactor == .double)

        viewModel.engineKind = .aiSuperResolution
        #expect(viewModel.scaleFactor == .quadruple)
    }

    @Test func availableScaleFactorsDependOnEngineKind() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: nil)
        #expect(viewModel.availableScaleFactors == [.quadruple])

        viewModel.engineKind = .traditional
        #expect(viewModel.availableScaleFactors == UpscaleExportViewModel.ScaleFactor.allCases)
        #expect(viewModel.availableScaleFactors.count == 2)
    }

    // AI版は4倍固定で倍率を下げられないため、出力px基準(入力px×16)で判定すると
    // 一般的な写真サイズでも常に上限超過になってしまう回帰があった。入力px基準で判定することを確認する
    @Test func aiEngineUsesInputPixelCountForSizeLimit() {
        // 24MP相当(6000x4000)の一般的な写真ではAI版でも上限超過にならない
        let normalPhoto = UpscaleExportViewModel(inputPixelSize: CGSize(width: 6000, height: 4000))
        #expect(normalPhoto.engineKind == .aiSuperResolution)
        #expect(!normalPhoto.exceedsSizeLimit)

        // 80MP相当(10000x8000)の巨大な写真ではAI版で上限超過になる
        let hugePhoto = UpscaleExportViewModel(inputPixelSize: CGSize(width: 10000, height: 8000))
        #expect(hugePhoto.exceedsSizeLimit)
    }

    // 従来方式(Lanczos)は倍率を下げれば出力pxが下がり上限を回避できることを確認する
    @Test func traditionalEngineUsesOutputPixelCountForSizeLimit() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: CGSize(width: 6000, height: 4000))
        viewModel.engineKind = .traditional

        viewModel.scaleFactor = .quadruple
        #expect(viewModel.exceedsSizeLimit)

        viewModel.scaleFactor = .double
        #expect(!viewModel.exceedsSizeLimit)
    }
}
