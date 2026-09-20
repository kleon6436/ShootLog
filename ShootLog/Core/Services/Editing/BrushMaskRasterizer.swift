import CoreGraphics
import CoreImage
import Foundation

/// `BrushStroke` 列を `CGContext` でグレースケールへラスタライズする（プラン §1.3）。
///
/// 自由形状のペイントは Core Image のフィルタチェーンで表現できないため、CPU 側の
/// `CGContext` へ円ブラシをスタンプ描画してから `CIImage` 化する。ストロークは
/// ベース空間の正規化座標（0...1）で保持されるので、任意の解像度でラスタライズしても
/// 相対的な見えが一致する（プレビュー 3200px とフル解像度書き出しの WYSIWYG）。
///
/// 出力は **符号付き**（-1...1）の単チャンネル画像で、`m = clamp(base + brush, 0, 1)` の
/// `brush` 項そのものにあたる。消しゴムを負値として持たないと、AI マスクやグラデーションが
/// 作ったベース（既に 1 の領域）をブラシで削れない。
enum BrushMaskRasterizer {

    /// 半径がこれ以下のストロークは描かない。1px 未満のスタンプは丸め次第で消えるため。
    private static let minimumRadiusPixels = 0.5

    /// 硬さ 100 でも境界に残す遷移帯（ピクセル）。0 にすると縁がジャギーになる
    /// （`MaskImageGenerator.minimumRadialTransitionPixels` と同じ趣旨）。
    private static let minimumEdgeTransitionPixels = 1.0

    /// スタンプ間隔の半径比。上限・下限と絶対下限（ピクセル）。
    private static let maximumStampSpacingFraction = 0.25
    private static let minimumStampSpacingFraction = 0.06
    private static let minimumStampSpacingPixels = 0.75

    /// 描画前に解決したストローク。座標はキャンバスのピクセル座標（左下原点）。
    private struct PreparedStroke {
        var points: [CGPoint]
        var radius: Double
        /// 0...1 に正規化済み。
        var hardness: Double
        /// 0...1 に正規化済み。
        var opacity: Double
        var isEraser: Bool
        /// 描画とアキュムレータ書き戻しの対象範囲（キャンバス内へクリップ済みの整数矩形）。
        var bounds: CGRect
    }

    // MARK: - 公開 API

    /// `strokes` を `baseExtent` の解像度でラスタライズする。
    ///
    /// 戻り値の extent は全ストロークを覆う最小矩形（`baseExtent` 内）であり `baseExtent` 全体ではない。
    /// `CIAdditionCompositing` は extent の外を 0 として扱うため、これで加算結果は変わらず、
    /// 大きな写真でブラシが一部にしかないときの確保量を抑えられる。
    /// 描くものが無ければ `nil`（呼び出し側は「ブラシ編集なし」として扱う）。
    static func rasterize(_ strokes: [BrushStroke], baseExtent: CGRect) -> CIImage? {
        guard !strokes.isEmpty, !baseExtent.isInfinite,
              baseExtent.width >= 1, baseExtent.width.isFinite,
              baseExtent.height >= 1, baseExtent.height.isFinite else {
            return nil
        }

        let width = Int(baseExtent.width.rounded())
        let height = Int(baseExtent.height.rounded())
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let shortEdge = Double(min(width, height))

        let prepared = strokes.compactMap { prepare($0, canvas: canvas, shortEdge: shortEdge) }
        guard let first = prepared.first else { return nil }
        let bounds = prepared.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let rowWidth = Int(bounds.width)
        let rowCount = Int(bounds.height)
        let pixelCount = rowWidth * rowCount
        var coverage = [UInt8](repeating: 0, count: pixelCount)
        var accumulator = [Float](repeating: 0, count: pixelCount)

        let didRasterize = coverage.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base, width: rowWidth, height: rowCount,
                      bitsPerComponent: 8, bytesPerRow: rowWidth,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            // キャンバス座標のまま描けるようビットマップの原点をずらす。
            context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)

            // ストローク 1 本ずつ共有バッファへ描いてはアキュムレータへ畳み込む。
            // 1 本の中の重なりは max（`.lighten`）で潰し、本数ぶんの加算・減算だけを積む。
            // 全スタンプを加算で重ねると、ゆっくり引いたストロークだけ濃くなる。
            for stroke in prepared {
                draw(stroke, in: context)
                accumulate(stroke, coverage: base, into: &accumulator, bounds: bounds, rowWidth: rowWidth)
            }
            return true
        }
        guard didRasterize else { return nil }

        return image(from: accumulator, bounds: bounds, baseExtent: baseExtent, rowWidth: rowWidth, rowCount: rowCount)
    }

    // MARK: - ストロークの解決

    private static func prepare(_ stroke: BrushStroke, canvas: CGRect, shortEdge: Double) -> PreparedStroke? {
        guard stroke.radius.isFinite, stroke.hardness.isFinite, stroke.opacity.isFinite else { return nil }

        // 半径は extent の短辺基準。縦横で基準を変えるとブラシが非正方形の写真で楕円になる
        // （`MaskImageGenerator.radialGradientImage` と同じ規約）。
        let radius = stroke.radius * shortEdge
        guard radius > minimumRadiusPixels else { return nil }

        let opacity = min(max(stroke.opacity, 0), 100) / 100
        guard opacity > 0 else { return nil }

        let points = stroke.points.compactMap { point -> CGPoint? in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            // 正規化座標は左上原点・y 下向き。`CGContext` は左下原点なので y を反転する。
            return CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height)
        }
        guard let firstPoint = points.first else { return nil }

        let hull = points.dropFirst().reduce(CGRect(origin: firstPoint, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        // 境界の 1px は遷移帯なので余分に含める。
        let bounds = hull.insetBy(dx: -CGFloat(radius) - 1, dy: -CGFloat(radius) - 1)
            .integral
            .intersection(canvas)
        guard !bounds.isEmpty else { return nil }

        return PreparedStroke(
            points: points,
            radius: radius,
            hardness: min(max(stroke.hardness, 0), 100) / 100,
            opacity: opacity,
            isEraser: stroke.isEraser,
            bounds: bounds
        )
    }

    // MARK: - 描画

    private static func draw(_ stroke: PreparedStroke, in context: CGContext) {
        context.setBlendMode(.copy)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(stroke.bounds)

        guard let gradient = makeGradient(hardness: stroke.hardness, opacity: stroke.opacity, radius: stroke.radius) else {
            return
        }

        // `.lighten` ＝ max 合成。1 本のストローク内でスタンプが重なっても濃度は上がらない。
        context.setBlendMode(.lighten)
        for point in stampPoints(stroke) {
            context.drawRadialGradient(
                gradient,
                startCenter: point, startRadius: 0,
                endCenter: point, endRadius: CGFloat(stroke.radius),
                options: [.drawsBeforeStartLocation]
            )
        }
    }

    /// 中心から `hardness * radius` までを `opacity` の芯、そこから外周にかけて 0 へ落とすブラシ断面。
    private static func makeGradient(hardness: Double, opacity: Double, radius: Double) -> CGGradient? {
        let core = min(hardness, max(0, 1 - minimumEdgeTransitionPixels / radius))
        // グレースケール色空間では 1 ストップあたり [輝度, アルファ] の 2 成分。
        let components: [CGFloat] = [CGFloat(opacity), 1, CGFloat(opacity), 1, 0, 1]
        let locations: [CGFloat] = [0, CGFloat(core), 1]
        return CGGradient(
            colorSpace: CGColorSpaceCreateDeviceGray(),
            colorComponents: components,
            locations: locations,
            count: locations.count
        )
    }

    /// 点列を等間隔に補間したスタンプ位置。
    private static func stampPoints(_ stroke: PreparedStroke) -> [CGPoint] {
        let step = stampSpacing(radius: stroke.radius, hardness: stroke.hardness)
        var result: [CGPoint] = [stroke.points[0]]
        for index in stroke.points.indices.dropFirst() {
            let start = stroke.points[index - 1]
            let end = stroke.points[index]
            let distance = Double(hypot(end.x - start.x, end.y - start.y))
            let segments = max(1, Int(distance / step))
            for segment in 1...segments {
                let t = CGFloat(Double(segment) / Double(segments))
                result.append(CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
        }
        return result
    }

    /// スタンプ間隔。max 合成なので、間隔が芯（`hardness * radius`）より広いとストロークの
    /// 背骨に波打ちが出る。硬いブラシは芯が広いので粗くてよく、柔らかいほど詰める。
    private static func stampSpacing(radius: Double, hardness: Double) -> Double {
        let fraction = min(maximumStampSpacingFraction, max(hardness, minimumStampSpacingFraction))
        return max(radius * fraction, minimumStampSpacingPixels)
    }

    // MARK: - 畳み込みと出力

    /// 1 本ぶんのカバレッジを符号付きアキュムレータへ足し込む（消しゴムは引く）。
    ///
    /// 各段で -1...1 へ丸める。ベース（`source`）はここでは見えないため、累積値が
    /// 無制限に伸びると「一度強く消した場所は二度と塗れない」という直感に反する挙動になる。
    private static func accumulate(
        _ stroke: PreparedStroke,
        coverage: UnsafePointer<UInt8>,
        into accumulator: inout [Float],
        bounds: CGRect,
        rowWidth: Int
    ) {
        let sign: Float = stroke.isEraser ? -1 : 1
        let rowCount = Int(bounds.height)
        let minX = Int(stroke.bounds.minX - bounds.minX)
        let maxX = Int(stroke.bounds.maxX - bounds.minX)
        let minY = Int(stroke.bounds.minY - bounds.minY)
        let maxY = Int(stroke.bounds.maxY - bounds.minY)

        for y in minY..<maxY {
            // ビットマップはメモリ先頭行が上端。キャンバス y（下から数える）と上下が逆。
            let row = (rowCount - 1 - y) * rowWidth
            for x in minX..<maxX {
                let index = row + x
                let value = Float(coverage[index]) / 255
                guard value > 0 else { continue }
                accumulator[index] = min(max(accumulator[index] + sign * value, -1), 1)
            }
        }
    }

    /// 符号付きアキュムレータを他の生成子と同じ「RGB == A == m」の `CIImage` にする。
    ///
    /// `composited(over:)` は通さない。負のアルファを source-over へ通す意味が定義されておらず、
    /// `CIAdditionCompositing` は extent 外を 0 として扱うので、そもそも土台が要らない。
    private static func image(
        from accumulator: [Float],
        bounds: CGRect,
        baseExtent: CGRect,
        rowWidth: Int,
        rowCount: Int
    ) -> CIImage? {
        let data = accumulator.withUnsafeBufferPointer { Data(buffer: $0) }
        let raw = CIImage(
            bitmapData: data,
            bytesPerRow: rowWidth * MemoryLayout<Float>.size,
            size: CGSize(width: rowWidth, height: rowCount),
            format: .Rf,
            colorSpace: nil
        )
        let positioned = raw.transformed(by: CGAffineTransform(
            translationX: baseExtent.origin.x + bounds.origin.x,
            y: baseExtent.origin.y + bounds.origin.y
        ))
        return positioned.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }
}
