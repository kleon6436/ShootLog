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
        #expect(neutral.vibrance == 0)
        #expect(neutral.saturation == 0)
        #expect(neutral.sharpness == 0)
        #expect(neutral.luminanceNoiseReduction == 0)
        #expect(neutral.colorNoiseReduction == 0)

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
        parameters.toneCurveRGB = [
            CurvePoint(x: 0, y: 0),
            CurvePoint(x: 0.5, y: 0.6),
            CurvePoint(x: 1, y: 1)
        ]
        parameters.hslSaturation[3] = 55
        parameters.colorNoiseReduction = 20

        let decoded = try roundTrip(parameters)
        #expect(decoded == parameters)
    }

    // MARK: - 欠損キーの補完

    @Test func emptyJSONObjectDecodesToNeutral() throws {
        let decoded = try decode(json: "{}")
        #expect(decoded == .neutral)
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
}
