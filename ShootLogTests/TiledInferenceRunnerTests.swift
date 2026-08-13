import CoreGraphics
import Foundation
import Testing

@testable import ShootLog

struct TiledInferenceRunnerTests {

    // MARK: - タイル配置

    @Test func tilesCoverEntireInput() {
        let layout = TileLayout.default
        let runner = TiledInferenceRunner(layout: layout)
        let sizes: [(Int, Int)] = [(1, 1), (127, 1), (128, 128), (129, 300), (4000, 3000), (1, 5000)]

        for (width, height) in sizes {
            let placements = runner.placements(inputWidth: width, inputHeight: height)
            #expect(!placements.isEmpty)

            var covered = [Bool](repeating: false, count: width * height)
            for placement in placements {
                for y in placement.inputOriginY..<(placement.inputOriginY + layout.inputTileSize) {
                    guard y < height else { break }
                    for x in placement.inputOriginX..<(placement.inputOriginX + layout.inputTileSize) {
                        guard x < width else { break }
                        covered[y * width + x] = true
                    }
                }
            }
            #expect(covered.allSatisfy { $0 }, "入力 \(width)x\(height) に未被覆の画素がある")
        }
    }

    @Test func adjacentTilesOverlapByConfiguredAmount() {
        let layout = TileLayout.default
        let runner = TiledInferenceRunner(layout: layout)
        let placements = runner.placements(inputWidth: 1000, inputHeight: 1000)

        let columnOrigins = Set(placements.map(\.inputOriginX)).sorted()
        #expect(columnOrigins.count > 1)
        for index in 1..<columnOrigins.count {
            let stride = columnOrigins[index] - columnOrigins[index - 1]
            #expect(stride == layout.inputStride)
            #expect(layout.inputTileSize - stride == layout.inputOverlap)
        }
    }

    @Test func tileOriginsAlwaysStayInsideInput() {
        let runner = TiledInferenceRunner(layout: .default)
        for width in [1, 7, 128, 129, 240, 241, 1023] {
            for placement in runner.placements(inputWidth: width, inputHeight: width) {
                #expect(placement.inputOriginX < width)
                #expect(placement.inputOriginY < width)
            }
        }
    }

    // MARK: - フェザーブレンド

    @Test func featherWeightsSumToOneEverywhere() {
        // 実寸レイアウトで全画素の重み総和マップを持つとテストが重いため、比率を保った縮小版を使う
        let layout = TileLayout(inputTileSize: 16, outputTileSize: 64, inputOverlap: 1)
        let runner = TiledInferenceRunner(layout: layout)
        #expect(layout.isValid)

        for (width, height) in [(1, 1), (16, 16), (17, 5), (40, 33), (61, 62)] {
            let map = runner.weightSumMap(inputWidth: width, inputHeight: height)
            #expect(map.count == width * height * layout.scaleFactor * layout.scaleFactor)
            for (index, sum) in map.enumerated() {
                #expect(
                    abs(Double(sum) - 1.0) < 1e-6,
                    "入力 \(width)x\(height) の出力画素 \(index) で重み総和が \(sum)"
                )
            }
        }
    }

    @Test func featherWeightsAreFlatAtImageEdges() {
        let weights = TiledInferenceRunner.featherWeights(
            tileSize: 64, overlap: 8, isFirst: true, isLast: true
        )
        #expect(weights.allSatisfy { $0 == 1 })

        let interior = TiledInferenceRunner.featherWeights(
            tileSize: 64, overlap: 8, isFirst: false, isLast: false
        )
        #expect(interior[0] < 0.2)
        #expect(interior[32] == 1)
        #expect(interior[63] < 0.2)
    }

    @Test func reflectedIndexMirrorsWithoutRepeatingEdge() {
        #expect(TiledInferenceRunner.reflectedIndex(0, length: 1) == 0)
        #expect(TiledInferenceRunner.reflectedIndex(5, length: 1) == 0)
        #expect(TiledInferenceRunner.reflectedIndex(3, length: 3) == 1)
        #expect(TiledInferenceRunner.reflectedIndex(4, length: 3) == 0)
        #expect(TiledInferenceRunner.reflectedIndex(2, length: 3) == 2)
    }

    // MARK: - 座標写像

    @Test func rotationMapsCornersWithoutOverlap() {
        for rotation in [0, 90, 180, 270] {
            let transform = PixelCoordinateTransform(sourceWidth: 4, sourceHeight: 3, rotation: rotation)
            var seen = Set<Int>()
            for y in 0..<3 {
                for x in 0..<4 {
                    let mapped = transform.map(x: x, y: y)
                    #expect(mapped.x >= 0 && mapped.x < transform.destinationWidth)
                    #expect(mapped.y >= 0 && mapped.y < transform.destinationHeight)
                    #expect(seen.insert(mapped.y * transform.destinationWidth + mapped.x).inserted)
                }
            }
            #expect(seen.count == 12)
        }
    }

    @Test func quarterTurnsSwapDestinationDimensions() {
        let rotated = PixelCoordinateTransform(sourceWidth: 4, sourceHeight: 3, rotation: 90)
        #expect(rotated.destinationWidth == 3)
        #expect(rotated.destinationHeight == 4)

        let upright = PixelCoordinateTransform(sourceWidth: 4, sourceHeight: 3, rotation: 180)
        #expect(upright.destinationWidth == 4)
        #expect(upright.destinationHeight == 3)
    }

    // MARK: - 実行

    @Test func lanczosEngineFillsBufferForTinyInput() async throws {
        let engine = LanczosSuperResolutionEngine(scaleFactor: 4)
        let input = try #require(TestImageFactory.makeSolidImage(width: 1, height: 1, red: 200, green: 100, blue: 50))
        let buffer = try #require(OutputPixelBuffer(width: 4, height: 4))
        let stream = AsyncStream<Double>.makeStream()

        try await engine.upscale(input, rotation: 0, into: buffer, progress: stream.continuation)
        stream.continuation.finish()

        let bytes = buffer.makeRGBA8Bytes()
        #expect(bytes.count == 4 * 4 * 4)
        // 単色入力なので拡大後も同じ色になる（フェザー重みが 1.0 でない場合は暗くなる）
        #expect(abs(Int(bytes[0]) - 200) <= 2)
        #expect(abs(Int(bytes[1]) - 100) <= 2)
        #expect(abs(Int(bytes[2]) - 50) <= 2)
    }

    @Test func extremeAspectRatioDoesNotThrow() async throws {
        let engine = LanczosSuperResolutionEngine(scaleFactor: 2)
        let input = try #require(TestImageFactory.makeSolidImage(width: 300, height: 1, red: 10, green: 20, blue: 30))
        let buffer = try #require(OutputPixelBuffer(width: 600, height: 2))
        let stream = AsyncStream<Double>.makeStream()

        try await engine.upscale(input, rotation: 0, into: buffer, progress: stream.continuation)
        stream.continuation.finish()

        let bytes = buffer.makeRGBA8Bytes()
        #expect(bytes.count == 600 * 2 * 4)
        #expect(abs(Int(bytes[0]) - 10) <= 2)
    }

    @Test func mismatchedBufferSizeIsRejected() async throws {
        let engine = LanczosSuperResolutionEngine(scaleFactor: 4)
        let input = try #require(TestImageFactory.makeSolidImage(width: 4, height: 2, red: 1, green: 2, blue: 3))
        // 90度回転では出力が 8x16 になるべきところへ 16x8 を渡す
        let buffer = try #require(OutputPixelBuffer(width: 16, height: 8))
        let stream = AsyncStream<Double>.makeStream()

        await #expect(throws: ShootLogError.self) {
            try await engine.upscale(input, rotation: 90, into: buffer, progress: stream.continuation)
        }
        stream.continuation.finish()
    }

    // MARK: - キャンセル

    @Test func cancellationStopsTileLoop() async throws {
        let runner = TiledInferenceRunner(layout: TileLayout(inputTileSize: 8, outputTileSize: 16, inputOverlap: 1))
        let input = try #require(TestImageFactory.makeSolidImage(width: 64, height: 64, red: 5, green: 5, blue: 5))
        let buffer = try #require(OutputPixelBuffer(width: 128, height: 128))
        let counter = TileCounter()

        let task = Task {
            try await runner.run(input: input, rotation: 0, into: buffer, progress: nil) { tile in
                await counter.increment()
                try await Task.sleep(for: .seconds(10))
                return tile
            }
        }

        // 最初のタイルの推論に入るまで待ってからキャンセルする
        while await counter.value == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        let processed = await counter.value
        #expect(processed < 64, "キャンセル後もタイル処理が続いている")
    }

    @Test func coreMLEngineWithoutModelReportsUnavailable() async {
        let engine = CoreMLSuperResolutionEngine(
            descriptor: SuperResolutionModelDescriptor(
                id: "not-installed", scaleFactor: 4, tileLayout: .default, isTrainedAlgorithmicMedia: true
            ),
            modelURL: nil
        )
        let availability = await engine.availability()
        #expect(availability == .unavailable(reason: .modelNotInstalled))
    }
}

// MARK: - テスト補助

actor TileCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

enum TestImageFactory {
    /// 単色の RGBA8 sRGB 画像を作る
    static func makeSolidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage? {
        guard width > 0, height > 0, let colorSpace = SuperResolutionColorSpace.sRGB else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = red
            bytes[index + 1] = green
            bytes[index + 2] = blue
            bytes[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
