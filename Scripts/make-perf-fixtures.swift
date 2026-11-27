// 性能計測用の合成 JPEG フィクスチャ（F-SYN、.omc/plans/macos27-optimization.md §3.1）を生成する。
// 使い方: Scripts/make-perf-fixtures.sh [出力先]（既定は ~/ShootLogPerfFixtures）
//
// 同じシードからは常に同じ画像になるよう、乱数は自前の線形合同法で作る。
// 偶数番目は埋め込みサムネイル付き、奇数番目はサムネイル無しで書き出し、
// サムネイル取得の両方の経路（埋め込みプレビュー / ImageIO 縮小）を通るようにする。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FixtureSet {
    let name: String
    let count: Int
    let width: Int
    let height: Int
}

// 一覧系（syn-1000 / syn-500）は件数が多いので 6MP、現像・書き出し用は計画どおり 24MP / 45MP
let fixtureSets = [
    FixtureSet(name: "syn-1000", count: 1_000, width: 3_000, height: 2_000),
    FixtureSet(name: "syn-500", count: 500, width: 3_000, height: 2_000),
    FixtureSet(name: "syn-24mp", count: 10, width: 6_000, height: 4_000),
    FixtureSet(name: "syn-45mp", count: 5, width: 8_256, height: 5_504),
]

struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
}

func makeImage(width: Int, height: Int, seed: UInt64) -> CGImage? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else { return nil }
    var random = SeededGenerator(seed: seed)

    // 背景のグラデーションで階調を、矩形と円で輪郭を作る（JPEG の圧縮量が実写に近くなるように）
    let top = CGColor(red: random.unit(), green: random.unit(), blue: random.unit(), alpha: 1)
    let bottom = CGColor(red: random.unit(), green: random.unit(), blue: random.unit(), alpha: 1)
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: width, y: height), options: []
        )
    }
    for _ in 0..<120 {
        context.setFillColor(red: random.unit(), green: random.unit(), blue: random.unit(), alpha: 0.6)
        let rect = CGRect(
            x: random.unit() * CGFloat(width), y: random.unit() * CGFloat(height),
            width: random.unit() * CGFloat(width) / 4, height: random.unit() * CGFloat(height) / 4
        )
        if random.next().isMultiple(of: 2) {
            context.fill(rect)
        } else {
            context.fillEllipse(in: rect)
        }
    }
    return context.makeImage()
}

func writeJPEG(_ image: CGImage, to url: URL, embedThumbnail: Bool) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
    ) else { return false }
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if embedThumbnail {
        properties[kCGImageDestinationEmbedThumbnail] = true
        properties[kCGImageDestinationImageMaxPixelSize] = max(image.width, image.height)
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

let outputRoot: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ShootLogPerfFixtures", isDirectory: true)
}()

var failures = 0
for set in fixtureSets {
    let directory = outputRoot.appendingPathComponent(set.name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<set.count {
        let url = directory.appendingPathComponent(String(format: "%@-%04d.jpg", set.name, index))
        // 既に生成済みなら作り直さない（同じシードなら同じ内容のため）
        if FileManager.default.fileExists(atPath: url.path) { continue }
        let seed = UInt64(truncatingIfNeeded: set.name.hashValueStable) &+ UInt64(index)
        guard let image = makeImage(width: set.width, height: set.height, seed: seed),
              writeJPEG(image, to: url, embedThumbnail: index.isMultiple(of: 2)) else {
            failures += 1
            FileHandle.standardError.write(Data("failed: \(url.path)\n".utf8))
            continue
        }
    }
    print("\(set.name): \(set.count) files in \(directory.path)")
}
exit(failures == 0 ? 0 : 1)

extension String {
    // String.hashValue は実行ごとに変わるため、シードには固定の FNV-1a を使う
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
