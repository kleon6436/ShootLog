import Foundation
import Testing

@testable import ShootLog

struct DevelopParametersTests {

    private func roundTrip(_ parameters: DevelopParameters) throws -> DevelopParameters {
        let data = try JSONEncoder().encode(parameters)
        return try JSONDecoder().decode(DevelopParameters.self, from: data)
    }

    private func decode(json: String) throws -> DevelopParameters {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(DevelopParameters.self, from: data)
    }

    private func fullyModifiedParameters() -> DevelopParameters {
        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        parameters.contrast = 2
        parameters.highlights = 3
        parameters.shadows = 4
        parameters.whites = 5
        parameters.blacks = 6
        parameters.brightness = 7
        parameters.temperature = 8
        parameters.tint = 9
        parameters.whiteBalance = WhiteBalanceSettings(mode: .custom, temperatureKelvin: 5_000, tint: 10)
        parameters.vibrance = 11
        parameters.saturation = 12
        parameters.toneCurveRGB = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
        parameters.toneCurveRed = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]
        parameters.toneCurveGreen = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.9)]
        parameters.toneCurveBlue = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.3), CurvePoint(x: 1, y: 1)]
        parameters.hslHue = Array(repeating: 13, count: HSLBand.allCases.count)
        parameters.hslSaturation = Array(repeating: 14, count: HSLBand.allCases.count)
        parameters.hslLuminance = Array(repeating: 15, count: HSLBand.allCases.count)
        parameters.clarity = 16
        parameters.structure = 17
        parameters.dehaze = 18
        parameters.vignette = 19
        parameters.sharpness = 20
        parameters.luminanceNoiseReduction = 21
        parameters.colorNoiseReduction = 22
        parameters.colorBalance.master = ColorBalanceComponent(hue: 23, saturation: 24, lightness: 25)
        parameters.blackAndWhiteEnabled = true
        parameters.bwMix = Array(repeating: 26, count: 6)
        parameters.lensCorrectionEnabled = true
        parameters.lensDistortion = 27
        parameters.lensVignette = 28
        parameters.lensChromaticAberration = 29
        return parameters
    }

    private func assertUnchangedSections(
        _ parameters: DevelopParameters,
        match before: DevelopParameters,
        excluding excludedSection: DevelopSection
    ) {
        if excludedSection != .basic {
            #expect(parameters.exposure == before.exposure)
            #expect(parameters.contrast == before.contrast)
            #expect(parameters.highlights == before.highlights)
            #expect(parameters.shadows == before.shadows)
            #expect(parameters.whites == before.whites)
            #expect(parameters.blacks == before.blacks)
            #expect(parameters.brightness == before.brightness)
        }
        if excludedSection != .whiteBalance {
            #expect(parameters.temperature == before.temperature)
            #expect(parameters.tint == before.tint)
            #expect(parameters.whiteBalance == before.whiteBalance)
        }
        if excludedSection != .color {
            #expect(parameters.vibrance == before.vibrance)
            #expect(parameters.saturation == before.saturation)
        }
        if excludedSection != .toneCurve {
            #expect(parameters.toneCurveRGB == before.toneCurveRGB)
            #expect(parameters.toneCurveRed == before.toneCurveRed)
            #expect(parameters.toneCurveGreen == before.toneCurveGreen)
            #expect(parameters.toneCurveBlue == before.toneCurveBlue)
        }
        if excludedSection != .hsl {
            #expect(parameters.hslHue == before.hslHue)
            #expect(parameters.hslSaturation == before.hslSaturation)
            #expect(parameters.hslLuminance == before.hslLuminance)
        }
        if excludedSection != .detail {
            #expect(parameters.clarity == before.clarity)
            #expect(parameters.structure == before.structure)
            #expect(parameters.dehaze == before.dehaze)
            #expect(parameters.vignette == before.vignette)
            #expect(parameters.sharpness == before.sharpness)
            #expect(parameters.luminanceNoiseReduction == before.luminanceNoiseReduction)
            #expect(parameters.colorNoiseReduction == before.colorNoiseReduction)
        }
        if excludedSection != .colorGrading {
            #expect(parameters.colorBalance == before.colorBalance)
        }
        if excludedSection != .blackAndWhite {
            #expect(parameters.blackAndWhiteEnabled == before.blackAndWhiteEnabled)
            #expect(parameters.bwMix == before.bwMix)
        }
        if excludedSection != .lens {
            #expect(parameters.lensCorrectionEnabled == before.lensCorrectionEnabled)
            #expect(parameters.lensDistortion == before.lensDistortion)
            #expect(parameters.lensVignette == before.lensVignette)
            #expect(parameters.lensChromaticAberration == before.lensChromaticAberration)
        }
    }

    // MARK: - neutral

    @Test func neutralHasAllDefaultValues() {
        let neutral = DevelopParameters.neutral

        #expect(neutral.exposure == 0)
        #expect(neutral.contrast == 0)
        #expect(neutral.highlights == 0)
        #expect(neutral.shadows == 0)
        #expect(neutral.whites == 0)
        #expect(neutral.blacks == 0)
        #expect(neutral.brightness == 0)
        #expect(neutral.temperature == 0)
        #expect(neutral.tint == 0)
        #expect(neutral.whiteBalance == .neutral)
        #expect(neutral.clarity == 0)
        #expect(neutral.structure == 0)
        #expect(neutral.dehaze == 0)
        #expect(neutral.vignette == 0)
        #expect(neutral.blackAndWhiteEnabled == false)
        #expect(neutral.bwMix == Array(repeating: 0, count: 6))
        #expect(neutral.colorBalance == .neutral)
        #expect(neutral.vibrance == 0)
        #expect(neutral.saturation == 0)
        #expect(neutral.sharpness == 0)
        #expect(neutral.luminanceNoiseReduction == 0)
        #expect(neutral.colorNoiseReduction == 0)
        #expect(neutral.lensDistortion == 0)
        #expect(neutral.lensVignette == 0)
        #expect(neutral.lensChromaticAberration == 0)

        #expect(neutral.toneCurveRGB == CurvePoint.identity)
        #expect(neutral.toneCurveRed == CurvePoint.identity)
        #expect(neutral.toneCurveGreen == CurvePoint.identity)
        #expect(neutral.toneCurveBlue == CurvePoint.identity)

        #expect(neutral.hslHue == Array(repeating: 0, count: 8))
        #expect(neutral.hslSaturation == Array(repeating: 0, count: 8))
        #expect(neutral.hslLuminance == Array(repeating: 0, count: 8))

        #expect(neutral.isNeutral)
        #expect(DevelopParameters().isNeutral)
    }

    @Test func mutatedValueIsNotNeutral() {
        var parameters = DevelopParameters.neutral
        parameters.exposure = 0.5
        #expect(!parameters.isNeutral)
    }

    // MARK: - セクションリセット

    @Test func resetEachSectionRestoresOnlyThatSection() {
        for section in DevelopSection.allCases {
            var parameters = fullyModifiedParameters()
            let before = parameters

            parameters.reset(section)

            #expect(!parameters.isModified(in: section))
            assertUnchangedSections(parameters, match: before, excluding: section)
        }
    }

    @Test func isModifiedReportsEachSection() {
        let neutral = DevelopParameters.neutral
        let parameters = fullyModifiedParameters()

        for section in DevelopSection.allCases {
            #expect(!neutral.isModified(in: section))
            #expect(parameters.isModified(in: section))
        }
    }

    @Test func resettingAllSectionsReturnsToNeutral() {
        var parameters = fullyModifiedParameters()

        for section in DevelopSection.allCases {
            parameters.reset(section)
        }

        #expect(parameters.isNeutral)
    }

    // MARK: - Codable round trip

    @Test func neutralSurvivesJSONRoundTrip() throws {
        let decoded = try roundTrip(.neutral)
        #expect(decoded == .neutral)
        #expect(decoded.isNeutral)
    }

    @Test func mutatedValueSurvivesJSONRoundTrip() throws {
        var parameters = DevelopParameters.neutral
        parameters.exposure = 1.25
        parameters.contrast = -40
        parameters.temperature = 15
        parameters.whiteBalance = .preset(.cloudy)
        parameters.clarity = 20
        parameters.dehaze = 30
        parameters.blackAndWhiteEnabled = true
        parameters.bwMix[0] = 25
        parameters.toneCurveRGB = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.5, y: 0.6),
            CurvePoint(x: 1, y: 1)
        ]
        parameters.hslSaturation[3] = 55
        parameters.colorNoiseReduction = 20
        parameters.lensCorrectionEnabled = true
        parameters.lensDistortion = 35
        parameters.lensVignette = -40
        parameters.lensChromaticAberration = 25

        let decoded = try roundTrip(parameters)
        #expect(decoded == parameters)
    }

    @Test func missingLensCorrectionKeyDefaultsToFalse() throws {
        let decoded = try decode(json: #"{"exposure": 1.0}"#)
        #expect(decoded.lensCorrectionEnabled == false)
        #expect(decoded.lensDistortion == 0)
        #expect(decoded.lensVignette == 0)
        #expect(decoded.lensChromaticAberration == 0)
    }

    // MARK: - 欠損キーの補完

    @Test func emptyJSONObjectDecodesToNeutral() throws {
        let decoded = try decode(json: "{}")
        #expect(decoded == .neutral)
    }

    @Test func legacyWhiteBalanceFieldsRemainCompatible() throws {
        let decoded = try decode(json: #"{"temperature": 20, "tint": -15}"#)
        #expect(decoded.temperature == 20)
        #expect(decoded.tint == -15)
        #expect(decoded.whiteBalance == .neutral)
    }

    @Test func malformedBWArrayIsNormalizedToSixBands() throws {
        let decoded = try decode(json: #"{"bwMix": [10, 20, 30, 40, 50, 60, 70]}"#)
        #expect(decoded.bwMix == [10, 20, 30, 40, 50, 60])
    }

    @Test func partialJSONFillsMissingKeysWithDefaults() throws {
        let decoded = try decode(json: #"{"exposure": 2.0}"#)
        #expect(decoded.exposure == 2.0)
        var expected = DevelopParameters.neutral
        expected.exposure = 2.0
        #expect(decoded == expected)
    }

    // MARK: - 不正データの正規化

    @Test func shortHSLArrayIsPaddedToEightBands() throws {
        let decoded = try decode(json: #"{"hslHue": [10, 20, 30]}"#)
        #expect(decoded.hslHue == [10, 20, 30, 0, 0, 0, 0, 0])
        #expect(decoded.hslSaturation.count == 8)
        #expect(decoded.hslLuminance.count == 8)
    }

    @Test func longHSLArrayIsTruncatedToEightBands() throws {
        let decoded = try decode(json: #"{"hslLuminance": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]}"#)
        #expect(decoded.hslLuminance == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func emptyToneCurveFallsBackToIdentity() throws {
        let decoded = try decode(json: #"{"toneCurveRGB": []}"#)
        #expect(decoded.toneCurveRGB == CurvePoint.identity)
    }

    // MARK: - HSLBand

    @Test func hslBandOrderMatchesArrayLayout() {
        #expect(HSLBand.allCases.count == 8)
        #expect(HSLBand.allCases == [.red, .orange, .yellow, .green, .aqua, .blue, .purple, .magenta])
    }

    @Test func hslBandCenterHues() {
        #expect(HSLBand.red.centerHue == 0)
        #expect(HSLBand.orange.centerHue == 30)
        #expect(HSLBand.yellow.centerHue == 60)
        #expect(HSLBand.green.centerHue == 120)
        #expect(HSLBand.aqua.centerHue == 180)
        #expect(HSLBand.blue.centerHue == 240)
        #expect(HSLBand.purple.centerHue == 280)
        #expect(HSLBand.magenta.centerHue == 320)
    }

    // MARK: - hslAdjustment(for:)

    @Test func hslAdjustmentReadsCorrectIndex() {
        var parameters = DevelopParameters.neutral
        parameters.hslSaturation[1] = 50
        parameters.hslHue[1] = -12
        parameters.hslLuminance[1] = 8

        let adjustment = parameters.hslAdjustment(for: .orange)
        #expect(adjustment.hue == -12)
        #expect(adjustment.saturation == 50)
        #expect(adjustment.luminance == 8)

        let red = parameters.hslAdjustment(for: .red)
        #expect(red.hue == 0)
        #expect(red.saturation == 0)
        #expect(red.luminance == 0)
    }

    @Test func hslAdjustmentReturnsZeroForMalformedArrays() {
        var parameters = DevelopParameters.neutral
        parameters.hslHue = [1, 2]
        parameters.hslSaturation = [3, 4]
        parameters.hslLuminance = [5, 6]

        // magenta (index 7) は配列範囲外 → (0, 0, 0)
        let adjustment = parameters.hslAdjustment(for: .magenta)
        #expect(adjustment.hue == 0)
        #expect(adjustment.saturation == 0)
        #expect(adjustment.luminance == 0)
    }

    // MARK: - 相対適用（applying(delta:)）

    @Test func applyingNeutralDeltaReturnsSelf() {
        var base = DevelopParameters.neutral
        base.exposure = 1.2
        base.toneCurveRGB = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]

        #expect(base.applying(delta: .neutral) == base)
    }

    @Test func applyingAddsScalarsAndClampsToRange() {
        var base = DevelopParameters.neutral
        base.exposure = 2.0
        base.contrast = 80
        base.saturation = -30

        var delta = DevelopParameters.neutral
        delta.exposure = 2.0      // 4.0 → 3.0 でクランプ
        delta.contrast = 40       // 120 → 100 でクランプ
        delta.saturation = 10     // -20

        let result = base.applying(delta: delta)
        #expect(result.exposure == 3.0)
        #expect(result.contrast == 100)
        #expect(result.saturation == -20)
    }

    @Test func applyingAddsHSLBandsElementwise() {
        var base = DevelopParameters.neutral
        base.hslSaturation[3] = 40

        var delta = DevelopParameters.neutral
        delta.hslSaturation[3] = 80    // 120 → 100
        delta.hslSaturation[0] = -10

        let result = base.applying(delta: delta)
        #expect(result.hslSaturation[3] == 100)
        #expect(result.hslSaturation[0] == -10)
    }

    @Test func applyingAddsColorBalanceComponentsAndPreservesBaseForNeutralDelta() {
        var base = DevelopParameters.neutral
        base.colorBalance.shadows.hue = 30
        base.colorBalance.shadows.saturation = 20

        var delta = DevelopParameters.neutral
        delta.colorBalance.shadows.hue = 160
        delta.colorBalance.shadows.saturation = -50
        #expect(base.applying(delta: delta).colorBalance.shadows.hue == 180)
        #expect(base.applying(delta: delta).colorBalance.shadows.saturation == 0)

        var neutralColorBalanceDelta = DevelopParameters.neutral
        neutralColorBalanceDelta.contrast = 10
        #expect(base.applying(delta: neutralColorBalanceDelta).colorBalance == base.colorBalance)
    }

    @Test func applyingComposesToneCurvesIdentityCases() {
        var base = DevelopParameters.neutral
        let curve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]
        base.toneCurveRGB = curve

        // delta のカーブが恒等なら base のカーブがそのまま残る。
        #expect(base.applying(delta: .neutral).toneCurveRGB == curve)

        // base が恒等なら delta のカーブがそのまま入る。
        var delta = DevelopParameters.neutral
        delta.toneCurveRGB = curve
        #expect(DevelopParameters.neutral.applying(delta: delta).toneCurveRGB == curve)
    }

    @Test func applyingComposesToneCurvesMonotonically() {
        var base = DevelopParameters.neutral
        base.toneCurveRGB = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]   // 全体を持ち上げ

        var delta = DevelopParameters.neutral
        delta.toneCurveRGB = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.9)]  // 全体を下げ

        let composed = base.applying(delta: delta).toneCurveRGB
        // 合成カーブは単調増加で 0...1 に収まる。
        let ys = ToneCurve.sampled(composed, count: 32)
        for (a, b) in zip(ys, ys.dropFirst()) {
            #expect(b >= a - 1e-9)
        }
        #expect(ys.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func applyingLensCorrectionIsLogicalOR() {
        var base = DevelopParameters.neutral
        base.lensCorrectionEnabled = true
        var deltaOff = DevelopParameters.neutral
        deltaOff.contrast = 5   // delta を非中立にする
        // delta 側が false でも base の true は保たれる。
        #expect(base.applying(delta: deltaOff).lensCorrectionEnabled == true)

        var deltaOn = DevelopParameters.neutral
        deltaOn.lensCorrectionEnabled = true
        #expect(DevelopParameters.neutral.applying(delta: deltaOn).lensCorrectionEnabled == true)
    }

    @Test func applyingAddsManualLensCorrectionAndClampsToRange() {
        var base = DevelopParameters.neutral
        base.lensDistortion = 80
        base.lensVignette = -80
        base.lensChromaticAberration = 10

        var delta = DevelopParameters.neutral
        delta.lensDistortion = 40
        delta.lensVignette = -40
        delta.lensChromaticAberration = -25

        let result = base.applying(delta: delta)
        #expect(result.lensDistortion == 100)
        #expect(result.lensVignette == -100)
        #expect(result.lensChromaticAberration == -15)
        #expect(base.applying(delta: .neutral) == base)
    }

    @Test func hasManualLensCorrectionTracksAllFields() {
        #expect(DevelopParameters.neutral.hasManualLensCorrection == false)

        var parameters = DevelopParameters.neutral
        parameters.lensDistortion = 1
        #expect(parameters.hasManualLensCorrection)
        parameters = .neutral
        parameters.lensVignette = 1
        #expect(parameters.hasManualLensCorrection)
        parameters = .neutral
        parameters.lensChromaticAberration = 1
        #expect(parameters.hasManualLensCorrection)
    }

    // MARK: - WhiteBalanceSample

    @Test func whiteBalanceSampleIsEquatable() {
        let sample = WhiteBalanceSample(temperatureKelvin: 5_600, tint: -5, isEstimated: false)
        #expect(sample == WhiteBalanceSample(temperatureKelvin: 5_600, tint: -5, isEstimated: false))
        #expect(sample != WhiteBalanceSample(temperatureKelvin: 5_600, tint: -5, isEstimated: true))
    }
}
