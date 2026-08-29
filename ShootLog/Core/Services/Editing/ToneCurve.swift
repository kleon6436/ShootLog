import Foundation

/// 正規化トーンカーブ（制御点列）を、Core Image `CIColorCurves` などへ渡すための
/// 等間隔サンプリング済みルックアップ配列へ変換する純粋数学ユーティリティ。
///
/// 制御点は x/y とも 0...1 の正規化座標で、x 昇順・端点 (x=0, x=1) を含むことを想定する。
/// 実際の入力は順不同・重複 x・範囲外・端点欠落を含みうるため、補間前に必ず正規化する。
/// 補間には単調 3 次エルミート補間（Fritsch–Carlson の monotone cubic Hermite）を用い、
/// 制御点が単調な列であればサンプル列も単調になり、0...1 の外へオーバーシュートしない。
enum ToneCurve {

    /// 恒等判定・制御点の重複除去・端点補完に用いる x 座標の許容誤差。
    private static let epsilon = 1e-6

    /// 制御点が実質的に恒等カーブ（`[(0,0), (1,1)]` 相当、許容誤差 `epsilon`）かどうか。
    ///
    /// `DevelopPipeline` が恒等時にカーブフィルタの挿入を省くための判定に使う。
    /// - Parameter points: 判定対象の制御点列。
    /// - Returns: ちょうど 2 点で、始点が (0,0)、終点が (1,1) に一致するとき `true`。
    static func isIdentity(_ points: [CurvePoint]) -> Bool {
        guard points.count == 2 else { return false }
        let start = points[0]
        let end = points[1]
        return abs(start.x) <= epsilon
            && abs(start.y) <= epsilon
            && abs(end.x - 1) <= epsilon
            && abs(end.y - 1) <= epsilon
    }

    /// `count` 個の等間隔 x（0...1）に対する y 値配列を返す。
    ///
    /// - Parameters:
    ///   - points: 正規化制御点列。順不同・重複 x・範囲外・端点欠落を許容する。
    ///   - count: サンプル数。`x = index / (count - 1)` で等間隔に評価する（`count == 1` は x=0 のみ）。
    /// - Returns: 各要素を 0...1 にクランプした、要素数がちょうど `count` の配列。
    ///   制御点が 2 点未満、または実質恒等カーブのときは線形（y = x）を返す。
    static func sampled(_ points: [CurvePoint], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        // count == 1 のとき分母 0 を避ける。index 0 → x = 0 に評価される。
        let denominator = Double(max(count - 1, 1))

        let prepared = prepare(points)
        guard prepared.count >= 2, !isIdentity(prepared) else {
            return (0..<count).map { Double($0) / denominator }
        }

        let tangents = monotoneTangents(prepared)
        return (0..<count).map { index in
            let x = Double(index) / denominator
            return clamp01(evaluate(prepared, tangents: tangents, at: x))
        }
    }

    /// `sampled` の `Float` 版。`CIColorCurves` の `curvesData` は Float32 前提のため用意する。
    static func lookupTable(_ points: [CurvePoint], count: Int) -> [Float] {
        sampled(points, count: count).map { Float($0) }
    }

    // MARK: - 前処理

    /// 生の制御点列を、x が厳密に増加し端点 (x=0, x=1) を含む列へ正規化する。
    ///
    /// - x/y を 0...1 にクランプ
    /// - x 昇順にソート
    /// - x 差が `epsilon` 以下の点は先頭の 1 点だけ残す（ゼロ除算・急勾配の回避）
    /// - 端点が無ければ最近傍の y で外挿補完する
    ///
    /// 正規化後に 2 点未満へ縮んだ場合はそのまま返し、呼び出し側で線形フォールバックさせる。
    private static func prepare(_ points: [CurvePoint]) -> [CurvePoint] {
        let clamped = points.map { CurvePoint(x: clamp01($0.x), y: clamp01($0.y)) }
        let sorted = clamped.sorted { $0.x < $1.x }

        var deduped: [CurvePoint] = []
        for point in sorted {
            if let last = deduped.last, point.x - last.x <= epsilon { continue }
            deduped.append(point)
        }

        guard deduped.count >= 2 else { return deduped }

        // 端点補完。x=0 に十分近い点は x=0 へ吸着させ、無ければ最近傍 y で足す。
        if deduped[0].x > epsilon {
            deduped.insert(CurvePoint(x: 0, y: deduped[0].y), at: 0)
        } else {
            deduped[0] = CurvePoint(x: 0, y: deduped[0].y)
        }
        let lastIndex = deduped.count - 1
        if deduped[lastIndex].x < 1 - epsilon {
            deduped.append(CurvePoint(x: 1, y: deduped[lastIndex].y))
        } else {
            deduped[lastIndex] = CurvePoint(x: 1, y: deduped[lastIndex].y)
        }

        return deduped
    }

    // MARK: - 単調 3 次エルミート補間

    /// Fritsch–Carlson 法で各制御点の接線（勾配）を求める。
    ///
    /// 前提: `points` は 2 点以上で x が厳密に増加している（`prepare` が保証）。
    /// 隣接する割線の符号が変わる点では接線を 0 にし、`α² + β² > 9` の区間では
    /// 接線を縮小して、補間結果が制御点の単調性を破らないようにする。
    private static func monotoneTangents(_ points: [CurvePoint]) -> [Double] {
        let n = points.count
        var secants = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            secants[i] = dx > 0 ? (points[i + 1].y - points[i].y) / dx : 0
        }

        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                let prev = secants[i - 1]
                let next = secants[i]
                // 極値・平坦部では接線 0（オーバーシュート防止）
                tangents[i] = prev * next <= 0 ? 0 : (prev + next) / 2
            }
        }

        for i in 0..<(n - 1) {
            let secant = secants[i]
            if abs(secant) < .ulpOfOne {
                tangents[i] = 0
                tangents[i + 1] = 0
                continue
            }
            let alpha = tangents[i] / secant
            let beta = tangents[i + 1] / secant
            let sumSquares = alpha * alpha + beta * beta
            if sumSquares > 9 {
                let tau = 3 / sumSquares.squareRoot()
                tangents[i] = tau * alpha * secant
                tangents[i + 1] = tau * beta * secant
            }
        }

        return tangents
    }

    /// 正規化済み制御点と接線から、指定 x での y 値をエルミート基底で評価する。
    private static func evaluate(_ points: [CurvePoint], tangents: [Double], at x: Double) -> Double {
        let n = points.count
        if x <= points[0].x { return points[0].y }
        if x >= points[n - 1].x { return points[n - 1].y }

        // 制御点数は小さいので線形探索で区間を特定する。
        var segment = n - 2
        for i in 0..<(n - 1) where x < points[i + 1].x {
            segment = i
            break
        }

        let x0 = points[segment].x
        let x1 = points[segment + 1].x
        let h = x1 - x0
        guard h > 0 else { return points[segment].y }

        let t = (x - x0) / h
        let t2 = t * t
        let t3 = t2 * t

        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2

        return h00 * points[segment].y
            + h10 * h * tangents[segment]
            + h01 * points[segment + 1].y
            + h11 * h * tangents[segment + 1]
    }

    /// NaN を 0 に倒しつつ 0...1 へクランプする。
    private static func clamp01(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        return min(max(value, 0), 1)
    }
}
