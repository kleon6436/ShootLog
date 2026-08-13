import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Core Image の Lanczos 補間による非AIフォールバックエンジン。
/// AIモデルが使えない環境でも同じパイプライン（タイル分割・フェザーブレンド・回転写像）を通す
struct LanczosSuperResolutionEngine: SuperResolutionEngine {
    let modelID = "lanczos"
    let scaleFactor: Int
    private let layout: TileLayout

    init(scaleFactor: Int = 4) {
        let clamped = max(1, scaleFactor)
        self.scaleFactor = clamped
        self.layout = TileLayout.scaled(by: clamped)
    }

    // CIContext はスレッドセーフで、生成コストが高いため共有する
    private static let sharedContext: CIContext = {
        var options: [CIContextOption: Any] = [:]
        if let colorSpace = SuperResolutionColorSpace.sRGB {
            options[.workingColorSpace] = colorSpace
            options[.outputColorSpace] = colorSpace
        }
        return CIContext(options: options)
    }()

    func availability() async -> EngineAvailability {
        .available(computeUnit: .cpuAndGPU)
    }

    func upscale(
        _ input: CGImage,
        rotation: Int,
        into buffer: OutputPixelBuffer,
        progress: AsyncStream<Double>.Continuation
    ) async throws {
        let runner = TiledInferenceRunner(layout: layout)
        let outputTileSize = layout.outputTileSize
        let scale = scaleFactor

        try await runner.run(input: input, rotation: rotation, into: buffer, progress: progress) { tile in
            guard let scaled = Self.scale(tile, by: scale, outputSize: outputTileSize) else {
                throw ShootLogError.superResolutionFailed(reason: "lanczos scaling failed")
            }
            return scaled
        }
    }

    /// タイル1枚を Lanczos で拡大する。
    /// タイル境界での暗falloffを避けるため、拡大前に `clampedToExtent()` で外周を延長する
    static func scale(_ tile: CGImage, by scaleFactor: Int, outputSize: Int) -> CGImage? {
        let source = CIImage(cgImage: tile)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = source.clampedToExtent()
        filter.scale = Float(scaleFactor)
        filter.aspectRatio = 1
        guard let output = filter.outputImage else { return nil }

        let rect = CGRect(x: 0, y: 0, width: CGFloat(outputSize), height: CGFloat(outputSize))
        if let colorSpace = SuperResolutionColorSpace.sRGB {
            return sharedContext.createCGImage(
                output, from: rect, format: .RGBA8, colorSpace: colorSpace
            )
        }
        return sharedContext.createCGImage(output, from: rect)
    }
}
