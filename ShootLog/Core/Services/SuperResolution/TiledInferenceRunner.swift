import CoreGraphics
import Foundation

/// タイル分割の寸法定義。オーバーラップは入力側の画素数で表し、出力側は倍率倍になる。
/// 数値は Phase0.6 の実測で確定させる予定のため、定数として差し替えられる形にしている
struct TileLayout: Sendable, Equatable {
    let inputTileSize: Int
    let outputTileSize: Int
    let inputOverlap: Int

    static let `default` = TileLayout(inputTileSize: 128, outputTileSize: 512, inputOverlap: 8)

    static func scaled(by scaleFactor: Int, inputTileSize: Int = 128, inputOverlap: Int = 8) -> TileLayout {
        TileLayout(
            inputTileSize: inputTileSize,
            outputTileSize: inputTileSize * max(1, scaleFactor),
            inputOverlap: inputOverlap
        )
    }

    var scaleFactor: Int { inputTileSize > 0 ? outputTileSize / inputTileSize : 1 }
    var inputStride: Int { inputTileSize - inputOverlap }
    var outputOverlap: Int { inputOverlap * scaleFactor }
    var outputStride: Int { inputStride * scaleFactor }

    /// フェザーの重み総和が 1.0 になる前提条件。オーバーラップがタイルの半分を超えると
    /// 先頭側と末尾側のランプが重なって成立しなくなる
    var isValid: Bool {
        inputTileSize > 0
            && inputOverlap >= 0
            && inputOverlap * 2 <= inputTileSize
            && inputStride > 0
            && outputTileSize > 0
            && outputTileSize % inputTileSize == 0
    }
}

/// 未回転出力座標系におけるタイル1枚の配置
struct TilePlacement: Sendable, Equatable {
    let column: Int
    let row: Int
    let inputOriginX: Int
    let inputOriginY: Int
    let outputOriginX: Int
    let outputOriginY: Int
    let isFirstColumn: Bool
    let isLastColumn: Bool
    let isFirstRow: Bool
    let isLastRow: Bool
}

/// 入力画像をタイルに切り出し、推論結果をフェザーブレンドで出力バッファへ合成する。
///
/// タイル配置のストライドは全タイルで一定にし、右端・下端のはみ出しは入力側の反射パディングと
/// 出力側のクリップで吸収する。ストライドを一定に保つことで、重なり合うタイルの重み総和が
/// 全画素でちょうど 1.0 になる（末端だけストライドを詰めると成立しない）
struct TiledInferenceRunner: Sendable {
    let layout: TileLayout

    init(layout: TileLayout = .default) {
        self.layout = layout
    }

    // MARK: - タイル配置

    /// 1軸方向のタイル枚数
    static func tileCount(length: Int, tileSize: Int, stride: Int) -> Int {
        guard length > 0, tileSize > 0, stride > 0 else { return 0 }
        guard length > tileSize else { return 1 }
        let remainder = length - tileSize
        return 1 + (remainder + stride - 1) / stride
    }

    /// 入力サイズに対するタイル配置一覧
    func placements(inputWidth: Int, inputHeight: Int) -> [TilePlacement] {
        guard layout.isValid, inputWidth > 0, inputHeight > 0 else { return [] }

        let columns = Self.tileCount(
            length: inputWidth, tileSize: layout.inputTileSize, stride: layout.inputStride
        )
        let rows = Self.tileCount(
            length: inputHeight, tileSize: layout.inputTileSize, stride: layout.inputStride
        )
        guard columns > 0, rows > 0 else { return [] }

        var result: [TilePlacement] = []
        result.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                result.append(
                    TilePlacement(
                        column: column,
                        row: row,
                        inputOriginX: column * layout.inputStride,
                        inputOriginY: row * layout.inputStride,
                        outputOriginX: column * layout.outputStride,
                        outputOriginY: row * layout.outputStride,
                        isFirstColumn: column == 0,
                        isLastColumn: column == columns - 1,
                        isFirstRow: row == 0,
                        isLastRow: row == rows - 1
                    )
                )
            }
        }
        return result
    }

    // MARK: - フェザー重み

    /// 1軸方向の線形フェザー重み（出力座標系）。
    /// 隣接タイルとの重なり領域を線形にランプさせ、画像の外側に隣接タイルが無い端では 1.0 で固定する
    static func featherWeights(tileSize: Int, overlap: Int, isFirst: Bool, isLast: Bool) -> [Float] {
        guard tileSize > 0 else { return [] }
        var weights = [Float](repeating: 1, count: tileSize)
        guard overlap > 0, overlap * 2 <= tileSize else { return weights }

        let denominator = Float(overlap)
        if !isFirst {
            for index in 0..<overlap {
                weights[index] = (Float(index) + 0.5) / denominator
            }
        }
        if !isLast {
            for offset in 0..<overlap {
                weights[tileSize - overlap + offset] = 1 - (Float(offset) + 0.5) / denominator
            }
        }
        return weights
    }

    /// 検証用に、出力座標系の各画素へ加算される重みの総和を求める
    func weightSumMap(inputWidth: Int, inputHeight: Int) -> [Float] {
        let outputWidth = inputWidth * layout.scaleFactor
        let outputHeight = inputHeight * layout.scaleFactor
        guard outputWidth > 0, outputHeight > 0 else { return [] }

        var map = [Float](repeating: 0, count: outputWidth * outputHeight)
        for placement in placements(inputWidth: inputWidth, inputHeight: inputHeight) {
            let weightX = Self.featherWeights(
                tileSize: layout.outputTileSize,
                overlap: layout.outputOverlap,
                isFirst: placement.isFirstColumn,
                isLast: placement.isLastColumn
            )
            let weightY = Self.featherWeights(
                tileSize: layout.outputTileSize,
                overlap: layout.outputOverlap,
                isFirst: placement.isFirstRow,
                isLast: placement.isLastRow
            )
            for ty in 0..<layout.outputTileSize {
                let y = placement.outputOriginY + ty
                guard y < outputHeight else { break }
                for tx in 0..<layout.outputTileSize {
                    let x = placement.outputOriginX + tx
                    guard x < outputWidth else { break }
                    map[y * outputWidth + x] += weightX[tx] * weightY[ty]
                }
            }
        }
        return map
    }

    // MARK: - 実行

    /// タイル単位の推論を回して出力バッファを埋める。
    ///
    /// この関数は `nonisolated` な async 関数として呼ばれることを前提とする。
    /// `Task.detached` を使わないのは、detached タスクがキャンセルを継承せず、
    /// タイルループのキャンセルが伝播しなくなるため（`HighResPrefetcher` の注記と同じ理由）
    func run(
        input: CGImage,
        rotation: Int,
        into buffer: OutputPixelBuffer,
        progress: AsyncStream<Double>.Continuation?,
        infer: @Sendable (CGImage) async throws -> CGImage
    ) async throws {
        guard layout.isValid else {
            throw ShootLogError.superResolutionFailed(reason: "invalid tile layout")
        }

        let inputWidth = input.width
        let inputHeight = input.height
        let outputWidth = inputWidth * layout.scaleFactor
        let outputHeight = inputHeight * layout.scaleFactor
        let transform = PixelCoordinateTransform(
            sourceWidth: outputWidth, sourceHeight: outputHeight, rotation: rotation
        )

        guard buffer.width == transform.destinationWidth,
              buffer.height == transform.destinationHeight else {
            throw ShootLogError.superResolutionFailed(reason: "output buffer size mismatch")
        }

        let tiles = placements(inputWidth: inputWidth, inputHeight: inputHeight)
        guard !tiles.isEmpty else {
            throw ShootLogError.superResolutionFailed(reason: "no tiles to process")
        }

        for (index, placement) in tiles.enumerated() {
            try Task.checkCancellation()

            guard let inputTile = Self.makeInputTile(
                from: input,
                originX: placement.inputOriginX,
                originY: placement.inputOriginY,
                size: layout.inputTileSize
            ) else {
                throw ShootLogError.superResolutionFailed(reason: "tile extraction failed")
            }

            let outputTile = try await infer(inputTile)
            guard outputTile.width == layout.outputTileSize,
                  outputTile.height == layout.outputTileSize else {
                throw ShootLogError.superResolutionFailed(reason: "unexpected inference output size")
            }
            guard let pixels = Self.makeRGBA8Bytes(from: outputTile) else {
                throw ShootLogError.superResolutionFailed(reason: "tile readback failed")
            }

            buffer.accumulate(
                tile: pixels,
                tileWidth: layout.outputTileSize,
                tileHeight: layout.outputTileSize,
                originX: placement.outputOriginX,
                originY: placement.outputOriginY,
                weightX: Self.featherWeights(
                    tileSize: layout.outputTileSize,
                    overlap: layout.outputOverlap,
                    isFirst: placement.isFirstColumn,
                    isLast: placement.isLastColumn
                ),
                weightY: Self.featherWeights(
                    tileSize: layout.outputTileSize,
                    overlap: layout.outputOverlap,
                    isFirst: placement.isFirstRow,
                    isLast: placement.isLastRow
                ),
                transform: transform
            )

            progress?.yield(Double(index + 1) / Double(tiles.count))
        }
    }

    // MARK: - 画素の切り出しと読み戻し

    /// 反射インデックス。端を重複させずに折り返す（… 2 1 0 1 2 …）
    static func reflectedIndex(_ index: Int, length: Int) -> Int {
        guard length > 1 else { return 0 }
        let period = 2 * (length - 1)
        var value = index % period
        if value < 0 { value += period }
        return value >= length ? period - value : value
    }

    /// 入力画像から1タイルを切り出す。画像外へはみ出す領域は反射パディングで埋める。
    /// 色空間変換はこのタイル単位でのみ行い、全画素バッファに対しては行わない
    static func makeInputTile(from image: CGImage, originX: Int, originY: Int, size: Int) -> CGImage? {
        guard size > 0, let colorSpace = SuperResolutionColorSpace.sRGB else { return nil }
        let bytesPerRow = size * 4
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .none
        // CG座標系は左下原点なので、タイル左上が入力の (originX, originY) に一致するよう平行移動する
        context.draw(
            image,
            in: CGRect(
                x: CGFloat(-originX),
                y: CGFloat(-(image.height - originY - size)),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )

        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * size)

        // ビットマップのメモリ行0は生成される CGImage の最上段に対応するため、
        // ここでは左上原点として扱ってよい
        let validWidth = min(size, max(0, image.width - originX))
        let validHeight = min(size, max(0, image.height - originY))
        guard validWidth > 0, validHeight > 0 else { return nil }

        if validWidth < size {
            for y in 0..<validHeight {
                let rowStart = y * bytesPerRow
                for x in validWidth..<size {
                    let sourceX = reflectedIndex(x, length: validWidth)
                    let destinationIndex = rowStart + x * 4
                    let sourceIndex = rowStart + sourceX * 4
                    for channel in 0..<4 {
                        bytes[destinationIndex + channel] = bytes[sourceIndex + channel]
                    }
                }
            }
        }
        if validHeight < size {
            for y in validHeight..<size {
                let sourceY = reflectedIndex(y, length: validHeight)
                let destinationRow = y * bytesPerRow
                let sourceRow = sourceY * bytesPerRow
                for offset in 0..<bytesPerRow {
                    bytes[destinationRow + offset] = bytes[sourceRow + offset]
                }
            }
        }

        return context.makeImage()
    }

    /// `CGImage` を RGBA8 のバイト列へ読み戻す
    static func makeRGBA8Bytes(from image: CGImage) -> [UInt8]? {
        guard let colorSpace = SuperResolutionColorSpace.sRGB else { return nil }
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        let succeeded = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        return succeeded ? bytes : nil
    }
}
