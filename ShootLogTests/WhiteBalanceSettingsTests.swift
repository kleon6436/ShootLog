import CoreGraphics
import Foundation
import Testing

@testable import ShootLog

struct WhiteBalanceSettingsTests {

    @Test func presetValuesAreAbsoluteAndStable() {
        let daylight = WhiteBalanceSettings.preset(.daylight)
        let tungsten = WhiteBalanceSettings.preset(.tungsten)

        #expect(daylight.mode == .daylight)
        #expect(daylight.temperatureKelvin == 5_500)
        #expect(tungsten.temperatureKelvin == 3_200)
        #expect(tungsten.hasEffect)
        #expect(WhiteBalanceSettings.preset(.asShot) == .neutral)
    }

    @Test func normalizeClampsInvalidKelvinAndTint() {
        var settings = WhiteBalanceSettings(mode: .custom, temperatureKelvin: .infinity, tint: .nan)
        settings.normalize()
        #expect(settings.temperatureKelvin == 6_500)
        #expect(settings.tint == 0)

        settings.temperatureKelvin = -10
        settings.tint = 1_000
        settings.normalize()
        #expect(settings.temperatureKelvin == WhiteBalanceSettings.minimumTemperature)
        #expect(settings.tint == 150)
    }

    @Test func automaticWhiteBalanceIsDeterministicForNeutralImage() throws {
        let image = try neutralImage()
        let first = try #require(WhiteBalanceResolver.automaticSettings(from: image))
        let second = try #require(WhiteBalanceResolver.automaticSettings(from: image))

        #expect(first == second)
        #expect(first.mode == .auto)
    }

    private func neutralImage() throws -> CGImage {
        let width = 16
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 160
            pixels[index + 1] = 160
            pixels[index + 2] = 160
            pixels[index + 3] = 255
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}
