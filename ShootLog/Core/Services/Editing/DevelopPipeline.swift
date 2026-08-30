import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// `DevelopParameters` を Core Image のフィルタチェーンとして入力画像へ適用する純粋関数群。
///
/// I/O を一切持たないため、プレビュー（縮小画像）と書き出し（フル解像度）の双方から
/// 同じコードを通せる。これが WYSIWYG（実装プラン §3 原則 1）の担保になる。
///
/// 適用順序は実装プラン §4.2 の固定順序に従う。各ステップは対応パラメータが中立なら
/// フィルタ自体を挟まないため、`DevelopParameters.neutral` では入力がそのまま返る。
/// HSL の色立方体（32³ の `CIColorCube` データ ≒ 512KB）を毎レンダー作り直さないための
/// 直近 1 件メモ。スライダー操作中は露出などが動く一方 HSL は据え置きになることが多く、
/// その間の cube 再生成を丸ごと省ける。
///
/// `NSLock` で保護し、返すのは値型の `Data`（コピー）なので、複数レンダーが並行しても安全。
/// そのため `@unchecked Sendable` を名乗ってよい。
final class DevelopPipelineCache: @unchecked Sendable {
    private struct Key: Equatable {
        let hue: [Double]
        let saturation: [Double]
        let luminance: [Double]
    }

    private let lock = NSLock()
    private var key: Key?
    private var cubeData: Data?

    /// HSL パラメータに対応する cube データ。中立なら `nil`。同一パラメータの連続要求は再計算しない。
    func hslCubeData(hue: [Double], saturation: [Double], luminance: [Double]) -> Data? {
        let requested = Key(hue: hue, saturation: saturation, luminance: luminance)
        lock.lock()
        defer { lock.unlock() }
        if key == requested { return cubeData }

        let computed = HSLColorCube.isNeutral(hue: hue, saturation: saturation, luminance: luminance)
            ? nil
            : HSLColorCube.cubeData(hue: hue, saturation: saturation, luminance: luminance)
        key = requested
        cubeData = computed
        return computed
    }
}

enum DevelopPipeline {

    // MARK: - 公開 API

    /// 調整チェーンを適用した画像を返す。
    ///
    /// - Parameters:
    ///   - parameters: 適用する調整値。
    ///   - input: ベースデコード済みの入力画像。
    ///   - isRAW: 入力が RAW 由来か。v1 ではノイズ低減の効き幅の選択にのみ使う
    ///     （RAW 固有パラメータの操作は行わず、すべて移植可能な標準 CIFilter で適用する）。
    ///   - cache: HSL cube の再計算を省くためのメモ。`nil` なら毎回計算する（テスト用の後方互換）。
    ///   - skipExposureAndWhiteBalance: RAW で露出・WB を `CIRAWFilter` 側へ委譲した場合に `true`。
    ///     このチェーンでは露出・色温度・色かぶりを適用しない（二重適用の防止）。
    ///   - applyManualLensCorrection: schemaVersion ゲートと、RAW のプロファイル補正が有効なら手動を
    ///     スキップする判断を呼び出し側で織り込んだ、手動レンズ補正の最終適用可否。
    /// - Returns: 調整後の画像。`parameters.isNeutral` の場合は `input` をそのまま返す。
    ///   フィルタ生成に失敗したステップは黙って読み飛ばし、直前の画像を維持する。
    ///
    /// ## 色管理（v3 Phase 1）
    ///
    /// チェーンは 2 つの評価空間に分かれる。呼び出し側の `CIContext` は作業空間 linearSRGB を
    /// 前提とする（`ImageDevelopmentEngine.sharedContext` と同じ）。
    ///
    /// - **リニア光**（作業空間そのまま）: ホワイトバランス・露出・ハイライト/シャドウ・シャープ・
    ///   ノイズ低減。物理的な光量の操作なので `ev = 1` が 2 倍になるリニア空間で評価する。
    /// - **ガンマ（sRGB）**: コントラスト・自然な彩度/彩度・白黒レベル・トーンカーブ・カラー別 HSL。
    ///   知覚的なトーン操作は sRGB エンコード値の上で評価するのが Capture One / Lightroom と同じ定石。
    ///   作業空間はリニアのままなので `linearToGamma` / `gammaToLinear`（`CI*ToneCurve*`）で前後を挟む。
    ///   この区間内のトーンカーブ・HSL フィルタは追加変換を避けるため作業空間（linearSRGB）を指定する。
    static func apply(
        _ parameters: DevelopParameters,
        to input: CIImage,
        isRAW: Bool,
        cache: DevelopPipelineCache? = nil,
        skipExposureAndWhiteBalance: Bool = false,
        applyManualLensCorrection: Bool = false
    ) -> CIImage {
        guard !parameters.isNeutral else { return input }

        var image = input

        // --- レンズ補正（幾何変形。他の調整より前）---
        if applyManualLensCorrection, parameters.hasManualLensCorrection {
            image = LensCorrectionFilter.corrected(
                image,
                distortion: parameters.lensDistortion,
                vignette: parameters.lensVignette,
                chromaticAberration: parameters.lensChromaticAberration
            )
        }

        // --- リニア光ブラケット（物理的な光の操作）---
        if !skipExposureAndWhiteBalance {
            image = applyWhiteBalance(parameters, to: image)
            image = applyExposure(parameters, to: image)
        }
        image = applyHighlightShadow(parameters, to: image)
        image = applyLocalContrast(parameters, to: image)
        image = applyDehaze(parameters, to: image)

        // --- ガンマ（sRGB）ブラケット（知覚的なトーン操作）---
        if hasPerceptualEffect(parameters) {
            image = linearToGamma(image)
            image = applyColorControls(parameters, to: image)
            image = applyVibrance(parameters, to: image)
            image = applyLevels(parameters, to: image)
            image = applyToneCurves(parameters, to: image)
            image = applyColorBalance(parameters, to: image)
            image = applyHSL(parameters, to: image, cache: cache)
            image = applyBlackAndWhite(parameters, to: image)
            image = applyVignette(parameters, to: image)
            image = gammaToLinear(image)
        }

        // --- リニア光ブラケット（ディテール）---
        image = applySharpness(parameters, to: image)
        image = applyNoiseReduction(parameters, to: image, isRAW: isRAW)

        // ぼかし・ノイズ低減系のフィルタは extent を広げたり縮めたりするため、入力の枠へ戻す。
        return image.extent == input.extent ? image : image.cropped(to: input.extent)
    }

    /// 何らかの調整が入っているか（`!parameters.isNeutral` の可読性用エイリアス）。
    static func hasAnyEffect(_ parameters: DevelopParameters) -> Bool {
        !parameters.isNeutral
    }

    /// ガンマ（sRGB）ブラケットで評価すべき知覚的なトーン調整が 1 つでも入っているか。
    /// すべて中立なら変換フィルタ 2 枚を挟まず、リニア光の調整だけを通す。
    static func hasPerceptualEffect(_ parameters: DevelopParameters) -> Bool {
        parameters.contrast != 0
            || parameters.brightness != 0
            || parameters.saturation != 0
            || parameters.vibrance != 0
            || parameters.clarity != 0
            || parameters.structure != 0
            || parameters.dehaze != 0
            || parameters.vignette != 0
            || parameters.blackAndWhiteEnabled
            || !parameters.colorBalance.isNeutral
            || parameters.whites != 0
            || parameters.blacks != 0
            || max(parameters.highlights, 0) != 0
            || !ToneCurve.isIdentity(parameters.toneCurveRGB)
            || !ToneCurve.isIdentity(parameters.toneCurveRed)
            || !ToneCurve.isIdentity(parameters.toneCurveGreen)
            || !ToneCurve.isIdentity(parameters.toneCurveBlue)
            || !HSLColorCube.isNeutral(
                hue: parameters.hslHue,
                saturation: parameters.hslSaturation,
                luminance: parameters.hslLuminance
            )
    }

    // MARK: - 作業空間 ↔ ガンマ空間の変換（知覚ブラケットの前後）

    /// 作業空間（linearSRGB）の値を sRGB ガンマ空間へエンコードする。知覚ブラケットの入口。
    private static func linearToGamma(_ image: CIImage) -> CIImage {
        let filter = CIFilter.linearToSRGBToneCurve()
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    /// sRGB ガンマ空間の値を作業空間（linearSRGB）へ戻す。知覚ブラケットの出口。
    private static func gammaToLinear(_ image: CIImage) -> CIImage {
        let filter = CIFilter.sRGBToneCurveToLinear()
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    /// 知覚ブラケット内のトーンカーブ・HSL フィルタへ渡す色空間。
    /// 画像は既にガンマエンコード済みなので、フィルタ側で再変換させず作業空間をそのまま指定する。
    private static let perceptualBracketColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: - マッピング係数

    /// `CITemperatureAndTint` の基準白色点（ケルビン）。
    private static let referenceTemperature: Double = 6500
    /// 色温度 1 単位あたりのケルビン。±100 で ±3500K ぶんのズレになる。
    private static let kelvinPerTemperatureUnit: Double = 35
    /// 色かぶり 1 単位あたりの CI tint 量。±100 で ±50（CI の tint は概ね -150...150 が実用域）。
    private static let ciTintPerTintUnit: Double = 0.5

    /// コントラスト ±100 で `CIColorControls.contrast` を 1.0 ± 0.5 に振る。
    private static let contrastSpan: Double = 0.5
    /// 明るさ ±100 で `CIColorControls.brightness` を 0 ± 0.3 に振る。
    private static let brightnessSpan: Double = 0.3

    /// `CIHighlightShadowAdjust.highlightAmount` の下限。実機の属性辞書で min = 0.3。
    /// これより下は CI 側でクランプされるだけなので、マッピングもこの値までで振り切る。
    private static let highlightRecoveryFloor: Double = 0.3

    /// `CIHighlightShadowAdjust.radius`（px）。既定の 0 だと空間マスクが無効で
    /// 単なるトーン圧縮になるため明示する。実機の属性辞書で max = 10。
    /// ピクセル単位なのでプレビュー（縮小画像）とフル解像度で厳密には効き方が変わるが、
    /// この程度の半径なら v1 では許容する。
    private static let highlightShadowRadius: Float = 5

    /// レベル調整（`CIToneCurve` 端点シフト）の効き幅。
    /// 制御点の順序が入れ替わってカーブが非単調になると破綻するため、
    /// point0 < point1(0.25) < point2(0.5) < point3 < point4 を保てる範囲に抑えている。
    private static let blacksSpan: Double = 0.08
    private static let highlightLiftSpan: Double = 0.12
    private static let whitesClipSpan: Double = 0.15
    private static let whitesDimSpan: Double = 0.10

    /// `CIColorCurves` へ渡す LUT のサンプル数。8bit 入力に対して十分な分解能。
    private static let curveSampleCount = 256

    /// `CIUnsharpMask` の半径（px）。プレビュー / フル解像度で見た目を揃えるため固定値にする。
    private static let sharpnessRadius: Float = 2.5
    /// シャープ +100 で `intensity` を 1.0 まで上げる。`CIUnsharpMask.intensity` の実効域は
    /// 0...1 なので、負方向（ソフト化）は v1 では非対応とし 0 でクランプする。
    private static let sharpnessIntensitySpan: Double = 1.0

    /// ノイズ低減の `noiseLevel` 上限。RAW は未処理ぶんノイズが多い前提で広く取る。
    private static let noiseLevelSpanRAW: Double = 0.10
    private static let noiseLevelSpanNonRAW: Double = 0.06
    /// `CINoiseReduction.sharpness`。CI の既定値をそのまま明示して、将来の既定変更に影響されないようにする。
    private static let noiseReductionSharpness: Float = 0.4

    // MARK: - 1. ホワイトバランス

    /// 色温度 / 色かぶり。`CITemperatureAndTint` は `targetNeutral / neutral` の比で
    /// 色順応させるため、**ソース側（`neutral`）を動かす**とスライダーの直感と一致する。
    /// 例えば `neutral` のケルビンを上げる = 「元画像は今より青い光源で撮られた」と宣言することになり、
    /// 結果は赤方向（暖色）へ寄る。色かぶりも同様に、正の値でマゼンタ方向へ寄る。
    private static func applyWhiteBalance(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        if parameters.whiteBalance.hasEffect {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(
                x: parameters.whiteBalance.temperatureKelvin,
                y: parameters.whiteBalance.tint
            )
            filter.targetNeutral = CIVector(x: referenceTemperature, y: 0)
            return filter.outputImage ?? image
        }
        guard parameters.temperature != 0 || parameters.tint != 0 else { return image }

        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(
            x: referenceTemperature + parameters.temperature * kelvinPerTemperatureUnit,
            y: parameters.tint * ciTintPerTintUnit
        )
        filter.targetNeutral = CIVector(x: referenceTemperature, y: 0)
        return filter.outputImage ?? image
    }

    // MARK: - 2. 露出

    private static func applyExposure(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        guard parameters.exposure != 0 else { return image }

        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        // exposure は他の調整と違い EV 単位なのでそのまま渡す。
        filter.ev = Float(parameters.exposure)
        return filter.outputImage ?? image
    }

    // MARK: - 3. ハイライト / シャドウ

    /// `CIHighlightShadowAdjust` は空間的なマスクを併用するため、単純なトーンカーブより
    /// ディテールを保ったままハイライト回復 / シャドウ持ち上げができる。
    ///
    /// ただしパラメータのレンジが非対称で、`shadowAmount` は -1...1 の対称レンジなのに対し
    /// `highlightAmount` は「1.0 = 無調整、0 に近づくほど暗く」という 0...1 の片側レンジしか
    /// 定義されていない。そのため**ハイライトを持ち上げる正方向はここでは扱えず**、
    /// `applyLevels` のトーンカーブ制御点側で処理している。
    private static func applyHighlightShadow(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        let recovery = min(parameters.highlights, 0)   // 負方向のみ（ハイライトを暗く）
        guard recovery != 0 || parameters.shadows != 0 else { return image }

        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        filter.radius = highlightShadowRadius
        filter.shadowAmount = Float(clamp(parameters.shadows / 100, -1, 1))
        // recovery ∈ [-1, 0] を highlightAmount の [floor, 1] へ線形写像し、
        // recovery = -1（highlights 最小）でちょうど下限に届くようにする。
        let recoveryRatio = clamp(recovery / 100, -1, 0)
        filter.highlightAmount = Float(1 + recoveryRatio * (1 - highlightRecoveryFloor))
        return filter.outputImage ?? image
    }

    // MARK: - 3.5 ローカルコントラスト / Dehaze

    private static func applyLocalContrast(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        guard parameters.clarity != 0 || parameters.structure != 0 else { return image }
        var result = image
        if parameters.clarity != 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = result
            filter.radius = 8
            filter.intensity = Float(parameters.clarity / 100 * 0.55)
            result = filter.outputImage ?? result
        }
        if parameters.structure != 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = result
            filter.radius = 2
            filter.intensity = Float(parameters.structure / 100 * 0.35)
            result = filter.outputImage ?? result
        }
        return result
    }

    private static func applyDehaze(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        guard parameters.dehaze != 0 else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        let amount = clamp(parameters.dehaze / 100, -1, 1)
        filter.contrast = Float(1 + amount * 0.35)
        filter.saturation = Float(max(0, 1 + amount * 0.18))
        return filter.outputImage ?? image
    }

    // MARK: - 4. コントラスト / 明るさ / 彩度

    /// v3 Phase 1 以降、この関数は `apply` の**ガンマ（sRGB）ブラケット内**で呼ばれる。
    /// 入力は既に sRGB エンコード済みで、`CIColorControls` はその値の上でコントラスト・
    /// 明るさ・彩度を評価する（白黒レベル・トーンカーブ・HSL と同じ空間）。
    /// コントラストの 0.5 ピボットや `contrastSpan` などの span 定数は、ガンマ空間前提での
    /// 実画像チューニングを別途行う（v3 Phase 1 の A 系統作業）。
    private static func applyColorControls(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        guard parameters.contrast != 0 || parameters.brightness != 0 || parameters.saturation != 0 else {
            return image
        }

        let filter = CIFilter.colorControls()
        filter.inputImage = image
        // いずれも 0 のときに CI の既定値（1.0 / 0 / 1.0）へ戻るようにマップする。
        filter.contrast = Float(1 + parameters.contrast / 100 * contrastSpan)
        filter.brightness = Float(parameters.brightness / 100 * brightnessSpan)
        filter.saturation = Float(max(0, 1 + parameters.saturation / 100))
        return filter.outputImage ?? image
    }

    // MARK: - 5. 自然な彩度

    private static func applyVibrance(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        guard parameters.vibrance != 0 else { return image }

        let filter = CIFilter.vibrance()
        filter.inputImage = image
        filter.amount = Float(clamp(parameters.vibrance / 100, -1, 1))
        return filter.outputImage ?? image
    }

    // MARK: - 6. 白 / 黒レベル（+ ハイライトの持ち上げ）

    /// 白 / 黒レベルを `CIToneCurve` の端点シフトとして適用する。
    /// `applyHighlightShadow` で扱えなかったハイライトの正方向（持ち上げ）も
    /// point3 の押し上げとしてここで合流させる。
    ///
    /// 5 つの制御点は既定で (0,0) (0.25,0.25) (0.5,0.5) (0.75,0.75) (1,1)。
    /// すべてのパラメータが中立ならフィルタを挟まないので、恒等性は保たれる。
    private static func applyLevels(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        let highlightLift = max(parameters.highlights, 0)
        guard parameters.whites != 0 || parameters.blacks != 0 || highlightLift != 0 else { return image }

        let filter = CIFilter.toneCurve()
        filter.inputImage = image

        // 黒レベル: 正で黒を持ち上げ（y を上げる）、負で黒を締める（入力側の x を右へ）。
        let blacksAmount = clamp(parameters.blacks / 100, -1, 1) * blacksSpan
        filter.point0 = blacksAmount >= 0
            ? CGPoint(x: 0, y: blacksAmount)
            : CGPoint(x: -blacksAmount, y: 0)
        filter.point1 = CGPoint(x: 0.25, y: 0.25)
        filter.point2 = CGPoint(x: 0.5, y: 0.5)

        filter.point3 = CGPoint(x: 0.75, y: 0.75 + highlightLift / 100 * highlightLiftSpan)

        // 白レベル: 正で白点を手前に引いてクリップを強め、負で白を落とす。
        let whitesRatio = clamp(parameters.whites / 100, -1, 1)
        filter.point4 = whitesRatio >= 0
            ? CGPoint(x: 1 - whitesRatio * whitesClipSpan, y: 1)
            : CGPoint(x: 1, y: 1 + whitesRatio * whitesDimSpan)

        return filter.outputImage ?? image
    }

    // MARK: - 7. トーンカーブ

    /// RGB マスターを先に適用し、続けて R/G/B チャンネル別カーブを適用する。
    /// 2 枚の `CIColorCurves` に分けているのは、1 枚へ合成するには
    /// マスター LUT を任意の位置で再補間する必要があり、精度と可読性が落ちるため。
    private static func applyToneCurves(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        var result = image

        if !ToneCurve.isIdentity(parameters.toneCurveRGB) {
            let master = ToneCurve.lookupTable(parameters.toneCurveRGB, count: curveSampleCount)
            result = colorCurves(result, red: master, green: master, blue: master) ?? result
        }

        let hasChannelCurve = !ToneCurve.isIdentity(parameters.toneCurveRed)
            || !ToneCurve.isIdentity(parameters.toneCurveGreen)
            || !ToneCurve.isIdentity(parameters.toneCurveBlue)
        if hasChannelCurve {
            // 恒等カーブに対しては ToneCurve.lookupTable が線形ランプを返すので、
            // 触っていないチャンネルはそのまま通過する。
            result = colorCurves(
                result,
                red: ToneCurve.lookupTable(parameters.toneCurveRed, count: curveSampleCount),
                green: ToneCurve.lookupTable(parameters.toneCurveGreen, count: curveSampleCount),
                blue: ToneCurve.lookupTable(parameters.toneCurveBlue, count: curveSampleCount)
            ) ?? result
        }

        return result
    }

    /// `CIColorCurves` を 1 枚適用する。
    ///
    /// `curvesData` は「サンプル数 × (R, G, B) の Float32」をインターリーブして並べたもので、
    /// フィルタはデータ長からサンプル数を推定する。`curvesDomain` は入力値の探索範囲。
    private static func colorCurves(
        _ image: CIImage,
        red: [Float],
        green: [Float],
        blue: [Float]
    ) -> CIImage? {
        let count = curveSampleCount
        guard red.count == count, green.count == count, blue.count == count else { return nil }

        var interleaved = [Float](repeating: 0, count: count * 3)
        for index in 0..<count {
            interleaved[index * 3] = red[index]
            interleaved[index * 3 + 1] = green[index]
            interleaved[index * 3 + 2] = blue[index]
        }

        let filter = CIFilter.colorCurves()
        filter.inputImage = image
        filter.curvesData = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        filter.curvesDomain = CIVector(x: 0, y: 1)
        // 画像は知覚ブラケットで既にガンマエンコード済み。フィルタ側で再変換させない。
        filter.colorSpace = perceptualBracketColorSpace
        return filter.outputImage
    }

    // MARK: - 8. カラー別 HSL

    private static func applyHSL(
        _ parameters: DevelopParameters,
        to image: CIImage,
        cache: DevelopPipelineCache?
    ) -> CIImage {
        // cache があれば cube データの再計算を省く。無ければ従来どおり毎回組む。
        let cubeData: Data?
        if let cache {
            cubeData = cache.hslCubeData(
                hue: parameters.hslHue,
                saturation: parameters.hslSaturation,
                luminance: parameters.hslLuminance
            )
        } else if HSLColorCube.isNeutral(
            hue: parameters.hslHue,
            saturation: parameters.hslSaturation,
            luminance: parameters.hslLuminance
        ) {
            cubeData = nil
        } else {
            cubeData = HSLColorCube.cubeData(
                hue: parameters.hslHue,
                saturation: parameters.hslSaturation,
                luminance: parameters.hslLuminance
            )
        }
        guard let cubeData else { return image }

        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(HSLColorCube.defaultDimension)
        filter.cubeData = cubeData
        // 画像は知覚ブラケットで既にガンマエンコード済み。フィルタ側で再変換させない。
        filter.colorSpace = perceptualBracketColorSpace
        return filter.outputImage ?? image
    }

    // MARK: - 8.5 カラーグレーディング / B&W / 周辺光量

    /// Core Image標準フィルターだけで実装できる安全な初期版。各トーン範囲の値は平均して効かせ、
    /// 将来の局所調整レイヤーでは同じ設定値をLUTベースのトーン分離へ差し替えられるようにする。
    private static func applyColorBalance(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        guard !parameters.colorBalance.isNeutral else { return image }
        let components = [
            parameters.colorBalance.master,
            parameters.colorBalance.shadows,
            parameters.colorBalance.midtones,
            parameters.colorBalance.highlights
        ]
        let hue = components.map(\.hue).reduce(0, +) / Double(components.count)
        let saturation = components.map(\.saturation).reduce(0, +) / Double(components.count)
        let lightness = components.map(\.lightness).reduce(0, +) / Double(components.count)
        var result = image
        if hue != 0 {
            let hueFilter = CIFilter.hueAdjust()
            hueFilter.inputImage = result
            hueFilter.angle = Float(hue / 180 * .pi)
            result = hueFilter.outputImage ?? result
        }
        let controls = CIFilter.colorControls()
        controls.inputImage = result
        controls.saturation = Float(max(0, 1 + saturation / 100))
        controls.brightness = Float(lightness / 100 * 0.15)
        return controls.outputImage ?? result
    }

    private static func applyBlackAndWhite(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        guard parameters.blackAndWhiteEnabled else { return image }
        let mix = parameters.bwMix + Array(repeating: 0, count: max(0, 6 - parameters.bwMix.count))
        let red = clamp(0.30 + mix[0] / 100 * 0.12, 0, 1)
        let green = clamp(0.59 + mix[3] / 100 * 0.12, 0, 1)
        let blue = clamp(0.11 + mix[5] / 100 * 0.12, 0, 1)
        let total = max(red + green + blue, 0.001)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        let vector = CIVector(x: red / total, y: green / total, z: blue / total, w: 0)
        filter.rVector = vector
        filter.gVector = vector
        filter.bVector = vector
        return filter.outputImage ?? image
    }

    private static func applyVignette(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        guard parameters.vignette != 0 else { return image }
        let filter = CIFilter.vignetteEffect()
        filter.inputImage = image
        filter.radius = Float(max(image.extent.width, image.extent.height) * 0.65)
        filter.intensity = Float(parameters.vignette / 100 * 1.5)
        return filter.outputImage ?? image
    }

    // MARK: - 9. シャープ

    private static func applySharpness(_ parameters: DevelopParameters, to image: CIImage) -> CIImage {
        let sharpen = max(parameters.sharpness, 0)   // 負方向（ソフト化）は v1 未対応
        guard sharpen > 0 else { return image }

        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = sharpnessRadius
        filter.intensity = Float(clamp(sharpen / 100, 0, 1) * sharpnessIntensitySpan)
        return filter.outputImage ?? image
    }

    // MARK: - 10. ノイズ低減

    /// `CINoiseReduction` は輝度ノイズとカラーノイズを分離して指定できず、
    /// `noiseLevel` と `sharpness` の 2 つしか持たない。v1 では輝度側に重みを置いて
    /// 2 つのスライダーを 1 つの `noiseLevel` へ合算する（カラーノイズ専用の経路は将来対応）。
    private static func applyNoiseReduction(
        _ parameters: DevelopParameters,
        to image: CIImage,
        isRAW: Bool
    ) -> CIImage {
        let luminance = max(parameters.luminanceNoiseReduction, 0)
        let color = max(parameters.colorNoiseReduction, 0)
        guard luminance > 0 || color > 0 else { return image }

        let combined = clamp((luminance * 0.7 + color * 0.3) / 100, 0, 1)
        let span = isRAW ? noiseLevelSpanRAW : noiseLevelSpanNonRAW

        let filter = CIFilter.noiseReduction()
        filter.inputImage = image
        filter.noiseLevel = Float(combined * span)
        filter.sharpness = noiseReductionSharpness
        return filter.outputImage ?? image
    }

    // MARK: - ヘルパー

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        // NaN は中立値 0 を許容範囲へ収めた値へ倒す（下限固定だと対称レンジで最大の負調整になる）。
        if value.isNaN { return min(max(0, lower), upper) }
        return min(max(value, lower), upper)
    }
}
