import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 現像エンジンの抽象。`DevelopViewModel` からはこの protocol 経由で使い、
/// テストではスパイ実装へ差し替えられるようにする。
///
/// v1 の描画系メソッドは throw せず、失敗を `nil` で返す。エラー種別を UI へ伝える必要が
/// 出た段階（Phase 5 の書き出し）で throwing + `ShootLogError` へ昇格させる予定。
protocol ImageDeveloping: Sendable {

    /// 表示用の縮小プレビューを現像して返す。
    /// - Parameter targetMaxPixelSize: 長辺の目標ピクセル数。0 以下・非有限を渡すとフル解像度扱い。
    func renderPreview(url: URL, parameters: DevelopParameters, targetMaxPixelSize: CGFloat) async -> CGImage?

    /// 書き出し用にフル解像度で現像して返す。
    func renderFull(url: URL, parameters: DevelopParameters) async -> CGImage?

    /// 拡張子から RAW かどうかを判定する。
    func isRAW(url: URL) -> Bool
}

/// `DevelopParameters` を実ファイルへ適用して CGImage を生成するエンジン。
///
/// 実装プラン §4.2 の 2 層キャッシュのうち Stage A（高コストなベースデコード）だけを
/// 保持する。Stage B（安価なフィルタチェーン）は `DevelopPipeline` が毎回組み直すため、
/// スライダー操作中は再デコードを伴わずに再レンダーできる。
actor ImageDevelopmentEngine: ImageDeveloping {

    static let shared = ImageDevelopmentEngine()

    /// CIContext はスレッドセーフで生成コストが高いため共有する。
    /// 露出・ハイライト/シャドウ・ノイズ低減はリニア光前提の演算のため、作業空間はリニア sRGB。
    /// ガンマ空間で処理すると `ev = 1` が物理的な 1 段（2 倍）にならない。出力は sRGB。
    private static let sharedContext: CIContext = {
        var options: [CIContextOption: Any] = [:]
        if let working = CGColorSpace(name: CGColorSpace.linearSRGB) {
            options[.workingColorSpace] = working
        }
        if let output = CGColorSpace(name: CGColorSpace.sRGB) {
            options[.outputColorSpace] = output
        }
        return CIContext(options: options)
    }()

    /// HSL cube の再計算を省くためのメモ。actor 隔離下の呼び出しからのみ渡すが、
    /// `DevelopPipelineCache` 自身も `NSLock` で保護しているため detached 実行でも安全。
    private let pipelineCache = DevelopPipelineCache()

    /// `CIRAWFilter` 経路でデコードする拡張子（小文字比較）。`CLAUDE.md` の対応拡張子に合わせる。
    /// ベースデコードは actor 外（detached）で走るため、実体は型レベルに置いている。
    static let rawExtensions: Set<String> = ["nef", "dng", "arw", "cr3", "raf"]

    /// Stage A キャッシュのサイズバケット幅（px）。要求解像度をこの刻みへ切り上げてキーにする。
    private static let bucketStep: CGFloat = 512
    /// Stage A キャッシュの最大エントリ数。写真を行き来する程度なら 2 枚で足りる。
    private static let cacheLimit = 2

    /// ベースデコード結果のキャッシュキー。フル解像度（bucket 0）はキャッシュ対象外。
    private struct BaseKey: Hashable {
        let path: String
        let sizeBucket: Int
    }

    private var baseImageCache: [BaseKey: CGImage] = [:]

    // MARK: - RAW 判定

    nonisolated func isRAW(url: URL) -> Bool {
        Self.rawExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - レンダリング

    func renderPreview(
        url: URL,
        parameters: DevelopParameters,
        targetMaxPixelSize: CGFloat
    ) async -> CGImage? {
        guard let base = await baseImage(url: url, targetMaxPixelSize: targetMaxPixelSize) else { return nil }
        guard !Task.isCancelled else { return nil }
        return await Self.develop(base: base, parameters: parameters, isRAW: isRAW(url: url), cache: pipelineCache)
    }

    /// フル解像度の現像結果を返す。
    ///
    /// 回転・トリミング（`EditInfo`）はこの Phase では適用しない。書き出しパイプラインへ
    /// 組み込む Phase 5 で、呼び出し側から明示的に渡す設計にする。
    ///
    /// フル解像度のベースはメモリを大きく食ううえ再利用機会も乏しいため、キャッシュしない。
    func renderFull(url: URL, parameters: DevelopParameters) async -> CGImage? {
        guard let base = await Self.decodeBase(url: url, maxPixelSize: 0) else { return nil }
        guard !Task.isCancelled else { return nil }
        return await Self.develop(base: base, parameters: parameters, isRAW: isRAW(url: url), cache: pipelineCache)
    }

    // MARK: - Stage A（ベースデコード + キャッシュ）

    private func baseImage(url: URL, targetMaxPixelSize: CGFloat) async -> CGImage? {
        let bucket = Self.sizeBucket(for: targetMaxPixelSize)
        let key = BaseKey(path: url.path, sizeBucket: bucket)

        if bucket > 0, let cached = baseImageCache[key] { return cached }

        // デコード中は actor が中断するため、同一キーの要求が重なると二重デコードになりうる。
        // 起きても結果は同じで、後勝ちでキャッシュされるだけなので、進行中タスクの共有は行わない。
        guard let decoded = await Self.decodeBase(
            url: url,
            maxPixelSize: Self.bucketPixelSize(bucket)
        ) else {
            return nil
        }

        if bucket > 0 { store(decoded, for: key) }
        return decoded
    }

    private func store(_ image: CGImage, for key: BaseKey) {
        if baseImageCache[key] == nil,
           baseImageCache.count >= Self.cacheLimit,
           let victim = baseImageCache.keys.first {
            baseImageCache.removeValue(forKey: victim)
        }
        baseImageCache[key] = image
    }

    /// 要求解像度を `bucketStep` 刻みへ切り上げたバケット番号。0 はフル解像度を表す。
    private static func sizeBucket(for targetMaxPixelSize: CGFloat) -> Int {
        guard targetMaxPixelSize.isFinite, targetMaxPixelSize > 0 else { return 0 }
        return max(1, Int((targetMaxPixelSize / bucketStep).rounded(.up)))
    }

    /// バケット番号に対応する長辺ピクセル数。0 のときはフル解像度（縮小しない）。
    private static func bucketPixelSize(_ bucket: Int) -> CGFloat {
        bucket <= 0 ? 0 : CGFloat(bucket) * bucketStep
    }

    /// 原本を読み、必要なら縮小したうえで CGImage として実体化する。
    ///
    /// `CIImage` は遅延評価なので、セキュリティスコープを閉じたあとに初めてピクセルを読みに行くと
    /// 失敗しうる。そのためスコープ内で `createCGImage` まで済ませてから返す。
    /// `Task.detached` はキャンセルを継承しないため `withTaskCancellationHandler` で伝播させる
    /// （`UpscaleExporter.decodeFullResolution` と同じ形）。
    private static func decodeBase(url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        let handle = Task.detached(priority: .userInitiated) { () -> CGImage? in
            // ブックマーク復元 URL に対してセキュリティスコープを要求する（通常 URL では no-op）
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            guard !Task.isCancelled else { return nil }
            return Self.decodeBaseSynchronously(url: url, maxPixelSize: maxPixelSize)
        }
        return await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    private static func decodeBaseSynchronously(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        let treatAsRAW = rawExtensions.contains(url.pathExtension.lowercased())

        var source: CIImage?
        if treatAsRAW {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            // RAW は scaleFactor を先に指定すると縮小デコードになり、後段の縮小より大幅に速い。
            // RAW 固有の現像パラメータ（exposure 等）は v1 では触らず as-shot 既定のまま使う。
            if maxPixelSize > 0 {
                let longestNativeSide = max(filter.nativeSize.width, filter.nativeSize.height)
                if longestNativeSide > 0 {
                    filter.scaleFactor = Float(min(1, maxPixelSize / longestNativeSide))
                }
            }
            source = filter.outputImage
        } else {
            source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }

        guard var image = source else { return nil }

        // RAW は scaleFactor で縮んでいるので、ここでの縮小は非 RAW のみ。拡大は行わない。
        if !treatAsRAW, maxPixelSize > 0 {
            let longestSide = max(image.extent.width, image.extent.height)
            if longestSide > maxPixelSize, longestSide > 0 {
                let filter = CIFilter.lanczosScaleTransform()
                filter.inputImage = image
                filter.scale = Float(maxPixelSize / longestSide)
                filter.aspectRatio = 1
                if let scaled = filter.outputImage { image = scaled }
            }
        }

        let rect = image.extent.integral
        guard !rect.isEmpty, !rect.isInfinite else { return nil }
        return sharedContext.createCGImage(image, from: rect)
    }

    // MARK: - Stage B（フィルタチェーン適用）

    private static func develop(
        base: CGImage,
        parameters: DevelopParameters,
        isRAW: Bool,
        cache: DevelopPipelineCache
    ) async -> CGImage? {
        let handle = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            let source = CIImage(cgImage: base)
            let adjusted = DevelopPipeline.apply(parameters, to: source, isRAW: isRAW, cache: cache)
            guard !Task.isCancelled else { return nil }

            let rect = adjusted.extent.integral
            guard !rect.isEmpty, !rect.isInfinite else { return nil }
            return sharedContext.createCGImage(adjusted, from: rect)
        }
        return await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
    }
}
