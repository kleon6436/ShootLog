import CoreGraphics
import Foundation
import Testing

@testable import ShootLog

struct HistogramDataTests {

    /// 指定 RGB の単色 CGImage（sRGB, RGBA8）を作る
    private func solidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = r
            pixels[index + 1] = g
            pixels[index + 2] = b
            pixels[index + 3] = 255
        }
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    @Test func emptyHistogramHasZeroedBins() {
        let empty = HistogramData.empty
        #expect(empty.red.count == HistogramData.binCount)
        #expect(empty.red.allSatisfy { $0 == 0 })
        #expect(empty.luminance.allSatisfy { $0 == 0 })
    }

    @Test func solidImageConcentratesAllPixelsInOneBin() async throws {
        let image = try solidImage(width: 16, height: 16, r: 200, g: 100, b: 50)
        let histogram = try #require(await HistogramData.make(from: image))

        #expect(histogram.red.count == 256)
        #expect(histogram.red[200] == 256)
        #expect(histogram.green[100] == 256)
        #expect(histogram.blue[50] == 256)
        // 他のビンは空
        #expect(histogram.red.reduce(0, +) == 256)
        #expect(histogram.green.reduce(0, +) == 256)
    }

    @Test func luminanceUsesRec709Weights() async throws {
        // 純緑は輝度が高め（係数 0.7152）
        let green = try solidImage(width: 8, height: 8, r: 0, g: 255, b: 0)
        let histogram = try #require(await HistogramData.make(from: green))

        let filledBin = try #require(histogram.luminance.firstIndex(where: { $0 > 0 }))
        #expect(filledBin >= 180 && filledBin <= 184)   // 255 * 0.7152 ≒ 182
        #expect(histogram.luminance[filledBin] == 64)
    }

    @Test func totalCountMatchesPixelCount() async throws {
        let image = try solidImage(width: 10, height: 7, r: 10, g: 20, b: 30)
        let histogram = try #require(await HistogramData.make(from: image))
        #expect(histogram.blue.reduce(0, +) == 70)
        #expect(histogram.luminance.reduce(0, +) == 70)
    }

    @Test func clippingFlagsTrackIndividualRGBAndLuminanceEdges() {
        var red = Array(repeating: 0, count: HistogramData.binCount)
        let green = red
        var blue = red
        var luminance = red
        red[255] = 1
        blue[0] = 1
        luminance[255] = 1
        let histogram = HistogramData(red: red, green: green, blue: blue, luminance: luminance)

        #expect(histogram.hasHighlightClipping)
        #expect(histogram.hasShadowClipping)
        #expect(histogram.hasLuminanceHighlightClipping)
        #expect(!histogram.hasLuminanceShadowClipping)
    }
}
