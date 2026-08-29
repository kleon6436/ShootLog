import CoreGraphics
import Foundation

/// 現像プレビューの RGB / 輝度ヒストグラム。各チャンネル 256 ビン。
///
/// 生成は `CGImage` を sRGB の RGBA8 へ一度だけ展開してビン集計するだけの純粋計算。
/// プレビュー解像度でもメインスレッドを塞がないよう、`make(from:)` は
/// バックグラウンドで実行する。
struct HistogramData: Sendable, Equatable {

    /// 各チャンネルのビン（要素数 256）。値はそのビンに入ったピクセル数。
    let red: [Int]
    let green: [Int]
    let blue: [Int]
    /// Rec.709 係数で求めた輝度のビン（要素数 256）。
    let luminance: [Int]

    static let binCount = 256

    /// 全ビン 0 の空ヒストグラム。
    static let empty = HistogramData(
        red: Array(repeating: 0, count: binCount),
        green: Array(repeating: 0, count: binCount),
        blue: Array(repeating: 0, count: binCount),
        luminance: Array(repeating: 0, count: binCount)
    )

    /// `CGImage` からヒストグラムを生成する（バックグラウンド実行）。
    static func make(from image: CGImage) async -> HistogramData? {
        await Task.detached(priority: .utility) {
            compute(from: image)
        }.value
    }

    // MARK: - Private

    private static func compute(from image: CGImage) -> HistogramData? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var red = [Int](repeating: 0, count: binCount)
        var green = [Int](repeating: 0, count: binCount)
        var blue = [Int](repeating: 0, count: binCount)
        var luminance = [Int](repeating: 0, count: binCount)

        var index = 0
        let pixelCount = width * height
        for _ in 0..<pixelCount {
            let r = Int(pixels[index])
            let g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2])
            red[r] += 1
            green[g] += 1
            blue[b] += 1
            // Rec.709。整数演算のため 1000 倍係数で丸める
            let y = (r * 2126 + g * 7152 + b * 722) / 10000
            luminance[min(binCount - 1, max(0, y))] += 1
            index += 4
        }

        return HistogramData(red: red, green: green, blue: blue, luminance: luminance)
    }
}
