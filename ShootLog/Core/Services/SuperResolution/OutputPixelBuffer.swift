import CoreGraphics
import Foundation

/// 未回転の出力座標 (x, y) を、回転適用後のバッファ座標へ写像する。
/// 回転済みのフルサイズ中間バッファを別途確保しないための座標変換であり、
/// `EditInfo.rotation`（時計回り 0 / 90 / 180 / 270）のみを扱う。EXIF orientation は適用しない
struct PixelCoordinateTransform: Sendable, Equatable {
    /// 未回転の出力幅
    let sourceWidth: Int
    /// 未回転の出力高さ
    let sourceHeight: Int
    /// 0 / 90 / 180 / 270 に正規化された回転角
    let rotation: Int

    init(sourceWidth: Int, sourceHeight: Int, rotation: Int) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.rotation = Self.normalized(rotation)
    }

    /// 90度単位以外の値は回転なしとして扱う（EditInfo.rotation は 90 度刻みのみを取る）
    static func normalized(_ rotation: Int) -> Int {
        let wrapped = ((rotation % 360) + 360) % 360
        return wrapped % 90 == 0 ? wrapped : 0
    }

    var isQuarterTurn: Bool { rotation % 180 != 0 }

    var destinationWidth: Int { isQuarterTurn ? sourceHeight : sourceWidth }

    var destinationHeight: Int { isQuarterTurn ? sourceWidth : sourceHeight }

    func map(x: Int, y: Int) -> (x: Int, y: Int) {
        switch rotation {
        case 90:
            return (sourceHeight - 1 - y, x)
        case 180:
            return (sourceWidth - 1 - x, sourceHeight - 1 - y)
        case 270:
            return (y, sourceWidth - 1 - x)
        default:
            return (x, y)
        }
    }
}

/// 超解像の出力先となる全画素バッファ。タイル単位の重み付き加算を受け付け、
/// 最終的に 8bit RGBA の `CGImage` を生成する。
///
/// 内部の累積は Float32 RGBA で保持する。8bit のまま加算するとタイル境界で
/// 丸め誤差が縞状に見えるため。1画素あたり16バイトを消費するので、
/// 消費量の上限は `UpscaleExporter.maximumOutputMegapixels` が決める。
///
/// タイル処理ループは単一タスクから逐次呼ばれるが、`Sendable` 要件を満たすため
/// 内部状態はロックで保護する
final class OutputPixelBuffer: @unchecked Sendable {
    let width: Int
    let height: Int

    private let lock = NSLock()
    private var accumulator: [Float]

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let count = width * height * 4
        guard count > 0 else { return nil }
        self.width = width
        self.height = height
        self.accumulator = [Float](repeating: 0, count: count)
    }

    /// タイル1枚分のRGBA8画素を、分離可能なフェザー重みを掛けて加算する。
    /// - Parameters:
    ///   - tile: RGBA8 の連続バイト列（1行 = `tileWidth * 4` バイト）
    ///   - originX: 未回転出力座標系におけるタイル左上のX
    ///   - originY: 未回転出力座標系におけるタイル左上のY
    ///   - weightX: 横方向の重み（長さ `tileWidth`）
    ///   - weightY: 縦方向の重み（長さ `tileHeight`）
    ///   - transform: 未回転出力座標からバッファ座標への写像
    func accumulate(
        tile: [UInt8],
        tileWidth: Int,
        tileHeight: Int,
        originX: Int,
        originY: Int,
        weightX: [Float],
        weightY: [Float],
        transform: PixelCoordinateTransform
    ) {
        guard tileWidth > 0, tileHeight > 0,
              tile.count >= tileWidth * tileHeight * 4,
              weightX.count >= tileWidth, weightY.count >= tileHeight else { return }

        lock.lock()
        defer { lock.unlock() }

        accumulator.withUnsafeMutableBufferPointer { destination in
            tile.withUnsafeBufferPointer { source in
                for ty in 0..<tileHeight {
                    let outY = originY + ty
                    guard outY >= 0, outY < transform.sourceHeight else { continue }
                    let wy = weightY[ty]
                    guard wy > 0 else { continue }
                    let sourceRow = ty * tileWidth * 4

                    for tx in 0..<tileWidth {
                        let outX = originX + tx
                        guard outX >= 0, outX < transform.sourceWidth else { continue }
                        let weight = weightX[tx] * wy
                        guard weight > 0 else { continue }

                        let mapped = transform.map(x: outX, y: outY)
                        let destinationIndex = (mapped.y * width + mapped.x) * 4
                        let sourceIndex = sourceRow + tx * 4
                        for channel in 0..<4 {
                            destination[destinationIndex + channel] +=
                                Float(source[sourceIndex + channel]) * weight
                        }
                    }
                }
            }
        }
    }

    /// 累積結果を 8bit RGBA のバイト列へ変換する
    func makeRGBA8Bytes() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBufferPointer { destination in
            accumulator.withUnsafeBufferPointer { source in
                for index in 0..<source.count {
                    let rounded = source[index].rounded()
                    destination[index] = UInt8(min(max(rounded, 0), 255))
                }
            }
        }
        return bytes
    }

    /// 累積結果を sRGB の `CGImage` として取り出す
    func makeCGImage() -> CGImage? {
        guard let colorSpace = SuperResolutionColorSpace.sRGB else { return nil }
        let bytes = makeRGBA8Bytes()
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
