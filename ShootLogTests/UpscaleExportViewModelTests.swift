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

    @Test func initialJPEGQualityIsHighest() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: nil)
        #expect(viewModel.jpegQuality == .highest)
        #expect(viewModel.jpegQuality.rawValue == 1.0)
    }

    // 品質はフォーマット非依存の設定として保持する（切り替えでリセットしない設計の回帰防止）
    @Test func jpegQualitySurvivesOutputFormatChanges() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: nil)
        viewModel.jpegQuality = .medium

        viewModel.outputFormat = .tiff
        #expect(viewModel.jpegQuality == .medium)

        viewModel.outputFormat = .jpeg
        #expect(viewModel.jpegQuality == .medium)
    }

    // AI版は4倍固定で倍率を下げて回避できないため、書き出しパイプラインの実上限
    // (UpscaleExporter.maximumOutputMegapixels)を超える入力では常に上限超過になる。
    // これは書き出し時のメモリ制約をUIが正しく反映した結果であり、
    // AI版だけ別の（実上限と食い違う）緩い目安値を使うのは誤り
    @Test func aiEngineUsesOutputPixelCountForSizeLimit() {
        let capPixels = Double(UpscaleExporter.maximumOutputMegapixels) * 1_000_000
        let quadrupleFactor = 16.0

        // 実上限の半分に収まる入力サイズでは超過にならない
        let safeInputSide = (capPixels / quadrupleFactor / 2).squareRoot()
        let safePhoto = UpscaleExportViewModel(inputPixelSize: CGSize(width: safeInputSide, height: safeInputSide))
        #expect(safePhoto.engineKind == .aiSuperResolution)
        #expect(!safePhoto.exceedsSizeLimit)

        // 24MP相当(6000x4000)は4倍出力(384MP)が実上限(160MP)を超えるため超過になる
        let normalPhoto = UpscaleExportViewModel(inputPixelSize: CGSize(width: 6000, height: 4000))
        #expect(normalPhoto.exceedsSizeLimit)
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

    // UIの上限判定値が書き出しパイプラインの実上限(UpscaleExporter.maximumOutputMegapixels)より
    // 低いと、実際は書き出せるはずの組み合わせもUIが不必要に「上限超過」として弾いてしまう
    // （100MP固定だった頃は6000x4000の一般的な写真ですら4倍で常に超過扱いになっていた）
    @Test func traditionalEngineSizeLimitMatchesExporterCap() {
        let capPixels = Double(UpscaleExporter.maximumOutputMegapixels) * 1_000_000
        let quadrupleFactor = 16.0
        let safeInputSide = (capPixels / quadrupleFactor / 2).squareRoot()
        let viewModel = UpscaleExportViewModel(
            inputPixelSize: CGSize(width: safeInputSide, height: safeInputSide)
        )
        viewModel.engineKind = .traditional
        viewModel.scaleFactor = .quadruple

        #expect(!viewModel.exceedsSizeLimit)
    }
}
