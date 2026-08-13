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
}
