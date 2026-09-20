import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

struct MaskRasterResolvingTests {

    // MARK: - ヘルパー

    /// 一様な値のグレースケール CGImage を作る。
    private func makeGrayImage(width: Int = 8, height: Int = 8, value: UInt8 = 200) throws -> CGImage {
        let pixels = [UInt8](repeating: value, count: width * height)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeRaster(id: UUID, pngData: Data, longEdge: Int = 8) -> MaskRaster {
        MaskRaster(id: id, pngData: pngData, longEdge: longEdge)
    }

    private func aiLayer(rasterID: UUID, isEnabled: Bool = true) -> MaskLayer {
        MaskLayer(
            id: UUID(),
            name: "ai",
            source: .ai(AIMaskReference(
                rasterID: rasterID,
                kind: .foregroundSubject,
                instanceIndices: [0],
                visionRevision: 1,
                bakedLongEdge: 8,
                bakedAt: .now
            )),
            isEnabled: isEnabled,
            adjustments: LocalAdjustments()
        )
    }

    // MARK: - 解決

    @Test func resolvesAIMaskRaster() throws {
        let rasterID = UUID()
        let image = try makeGrayImage()
        let raster = makeRaster(id: rasterID, pngData: try pngData(from: image))

        let resolved = MaskRasterResolving.resolve(masks: [aiLayer(rasterID: rasterID)], rasters: [raster])

        #expect(resolved.count == 1)
        let decoded = try #require(resolved[rasterID])
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
    }

    @Test func missingRasterIsOmitted() throws {
        let present = UUID()
        let raster = makeRaster(id: present, pngData: try pngData(from: try makeGrayImage()))

        let resolved = MaskRasterResolving.resolve(masks: [aiLayer(rasterID: UUID())], rasters: [raster])

        #expect(resolved.isEmpty)
    }

    @Test func disabledLayerIsSkipped() throws {
        let rasterID = UUID()
        let raster = makeRaster(id: rasterID, pngData: try pngData(from: try makeGrayImage()))

        let resolved = MaskRasterResolving.resolve(
            masks: [aiLayer(rasterID: rasterID, isEnabled: false)],
            rasters: [raster]
        )

        #expect(resolved.isEmpty)
    }

    @Test func nonAISourcesAreIgnored() throws {
        let rasterID = UUID()
        let raster = makeRaster(id: rasterID, pngData: try pngData(from: try makeGrayImage()))
        let gradient = MaskLayer(
            id: UUID(),
            name: "linear",
            source: .linearGradient(LinearGradientMask(
                start: NormalizedPoint(x: 0, y: 0),
                end: NormalizedPoint(x: 1, y: 1)
            )),
            adjustments: LocalAdjustments()
        )
        let radial = MaskLayer(
            id: UUID(),
            name: "radial",
            source: .radialGradient(RadialGradientMask(
                center: NormalizedPoint(x: 0.5, y: 0.5),
                radius: 0.3, aspectRatio: 1, rotationDegrees: 0, falloff: 50
            )),
            adjustments: LocalAdjustments()
        )

        let resolved = MaskRasterResolving.resolve(masks: [gradient, radial], rasters: [raster])

        #expect(resolved.isEmpty)
    }

    @Test func undecodablePNGIsOmitted() throws {
        let rasterID = UUID()
        let raster = makeRaster(id: rasterID, pngData: Data([0x00, 0x01, 0x02, 0x03]))

        let resolved = MaskRasterResolving.resolve(masks: [aiLayer(rasterID: rasterID)], rasters: [raster])

        #expect(resolved.isEmpty)
    }

    @Test func resolvesOnlyReferencedRasters() throws {
        let referenced = UUID()
        let unreferenced = UUID()
        let data = try pngData(from: try makeGrayImage())

        let resolved = MaskRasterResolving.resolve(
            masks: [aiLayer(rasterID: referenced)],
            rasters: [makeRaster(id: referenced, pngData: data), makeRaster(id: unreferenced, pngData: data)]
        )

        #expect(Set(resolved.keys) == [referenced])
    }
}
