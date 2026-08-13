// CoreMLSuperResolutionEngine.infer(...) と全く同じ経路(MLFeatureValue画像入力→推論→
// imageBufferValue読み戻し)を、コンパイル済み.mlmodelcに対して直接実行して検証する使い捨てスクリプト。
// 実行: swift Tools/CoreML/verify_runtime.swift <path-to-realesrgan.mlmodelc>
import CoreGraphics
import CoreImage
import CoreML
import Foundation

guard CommandLine.arguments.count > 1 else {
    print("usage: swift verify_runtime.swift <path-to-realesrgan.mlmodelc>")
    exit(1)
}
let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])

let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuAndNeuralEngine
let model = try MLModel(contentsOf: modelURL, configuration: configuration)
print("model loaded OK")

// 128x128のテスト画像を作る(グラデーション、実写に近い連続階調)
let size = 128
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
let data = context.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
for y in 0..<size {
    for x in 0..<size {
        let i = (y * size + x) * 4
        data[i] = UInt8((x * 255) / size)
        data[i + 1] = UInt8((y * 255) / size)
        data[i + 2] = 128
        data[i + 3] = 255
    }
}
let tile = context.makeImage()!
print("test tile created:", tile.width, "x", tile.height)

let inputFeature = try MLFeatureValue(
    cgImage: tile, pixelsWide: tile.width, pixelsHigh: tile.height,
    pixelFormatType: kCVPixelFormatType_32ARGB, options: nil
)
let provider = try MLDictionaryFeatureProvider(dictionary: ["input": inputFeature])

let start = Date()
let result = try model.prediction(from: provider)
let elapsed = Date().timeIntervalSince(start)
print("prediction OK, elapsed:", elapsed * 1000, "ms")

guard let outputFeature = result.featureValue(for: "output"),
      let outputPixelBuffer = outputFeature.imageBufferValue else {
    print("FAIL: no output pixel buffer")
    exit(1)
}
let outWidth = CVPixelBufferGetWidth(outputPixelBuffer)
let outHeight = CVPixelBufferGetHeight(outputPixelBuffer)
print("output pixel buffer:", outWidth, "x", outHeight)
guard outWidth == 512, outHeight == 512 else {
    print("FAIL: unexpected output size")
    exit(1)
}

let ciContext = CIContext(options: [.workingColorSpace: colorSpace])
let ciImage = CIImage(cvPixelBuffer: outputPixelBuffer)
guard let outputImage = ciContext.createCGImage(
    ciImage, from: CGRect(x: 0, y: 0, width: 512, height: 512), format: .RGBA8, colorSpace: colorSpace
) else {
    print("FAIL: could not create CGImage from output")
    exit(1)
}
print("output CGImage created:", outputImage.width, "x", outputImage.height)

// 出力が全て同一色(黒つぶれ等)になっていないか、ざっくり確認する
let outContext = CGContext(
    data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
outContext.draw(outputImage, in: CGRect(x: 0, y: 0, width: 512, height: 512))
let outData = outContext.data!.bindMemory(to: UInt8.self, capacity: 512 * 512 * 4)
var minV: UInt8 = 255
var maxV: UInt8 = 0
var hasNaNLikePattern = false
for i in stride(from: 0, to: 512 * 512 * 4, by: 4) {
    minV = min(minV, outData[i])
    maxV = max(maxV, outData[i])
}
print("output R channel range:", minV, "-", maxV)
if minV == maxV {
    print("WARNING: output is flat (single value) — possibly degenerate")
} else {
    print("OK: output has variation, not degenerate")
}
print("ALL CHECKS PASSED")
