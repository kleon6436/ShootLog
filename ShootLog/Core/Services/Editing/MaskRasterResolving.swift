import CoreGraphics
import Foundation
import ImageIO

/// `DevelopParameters.masks` の AI マスク参照（`.ai(AIMaskReference)`）を、対応する
/// `MaskRaster` の PNG データから `[UUID: CGImage]` へ解決する。
///
/// `MaskRaster` は `@Model` で `Sendable` でないため、engine の `Task.detached` へ直接渡せない。
/// 呼び出し側（MainActor）がここで値（`CGImage`）へ落としてから渡す契約になっている（§3.2.1）。
enum MaskRasterResolving {

    /// - Parameters:
    ///   - masks: 解決対象のマスクレイヤー一覧。
    ///   - rasters: 親 `DevelopSettings.maskRasters`（候補となる全ラスタ）。
    /// - Returns: `rasterID` ごとのデコード済み `CGImage`。デコード失敗や該当 `MaskRaster` が
    ///   見つからないレイヤーは辞書に含めない（描画側は未解決 `rasterID` を全面 0 として扱う）。
    static func resolve(masks: [MaskLayer], rasters: [MaskRaster]) -> [UUID: CGImage] {
        var result: [UUID: CGImage] = [:]
        for layer in masks where layer.isEnabled {
            guard case .ai(let reference) = layer.source else { continue }
            guard let raster = rasters.first(where: { $0.id == reference.rasterID }),
                  let decoded = decodeCGImage(from: raster.pngData) else { continue }
            result[reference.rasterID] = decoded
        }
        return result
    }

    /// `SubjectMaskGenerator` の PNG エンコードと対になるデコード処理。
    static func decodeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
