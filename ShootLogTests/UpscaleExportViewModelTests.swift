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

    // 2倍モデル同梱前は「AI選択時は4倍固定」だった。倍率を選んだままエンジンを
    // AIへ切り替えても倍率が勝手に書き換わらないことを確認する（強制ロジック撤廃の回帰防止）
    @Test func switchingToAIEngineKeepsSelectedScale() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: nil)

        viewModel.engineKind = .traditional
        viewModel.scaleFactor = .double
        #expect(viewModel.scaleFactor == .double)

        viewModel.engineKind = .aiSuperResolution
        #expect(viewModel.scaleFactor == .double)
    }

    // 倍率を変えてもエンジン選択が強制変更されないこと
    @Test func changingScaleKeepsSelectedEngine() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: nil)
        #expect(viewModel.engineKind == .aiSuperResolution)

        viewModel.scaleFactor = .double
        #expect(viewModel.engineKind == .aiSuperResolution)

        viewModel.scaleFactor = .quadruple
        #expect(viewModel.engineKind == .aiSuperResolution)
    }

    // AI版の選択肢はカタログ登録済みモデルの倍率に連動する（2倍・4倍とも同梱済み）
    @Test func availableScaleFactorsCoverBothEngines() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: nil)
        #expect(viewModel.availableScaleFactors.contains(.double))
        #expect(viewModel.availableScaleFactors.contains(.quadruple))
        #expect(viewModel.availableScaleFactors.count == 2)

        viewModel.engineKind = .traditional
        #expect(viewModel.availableScaleFactors == UpscaleExportViewModel.ScaleFactor.allCases)
        #expect(viewModel.availableScaleFactors.count == 2)
    }

    // AI版でも上限超過時に倍率を下げて回避できる（2倍モデル同梱前はAI版だけ下げられなかった）
    @Test func reduceScaleWorksForAIEngine() {
        let viewModel = UpscaleExportViewModel(inputPixelSize: CGSize(width: 6000, height: 4000))
        #expect(viewModel.engineKind == .aiSuperResolution)
        #expect(viewModel.scaleFactor == .quadruple)
        #expect(viewModel.exceedsSizeLimit)

        viewModel.reduceScale()
        #expect(viewModel.scaleFactor == .double)
        #expect(!viewModel.exceedsSizeLimit)
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

    // AI版も書き出しパイプラインの実上限(UpscaleExporter.maximumOutputMegapixels)を基準にする。
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
