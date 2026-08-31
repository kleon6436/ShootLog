import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 現像エンジンの抽象。`DevelopViewModel` からはこの protocol 経由で使い、
/// テストではスパイ実装へ差し替えられるようにする。
///
/// v1 の描画系メソッドは throw せず、失敗を `nil` で返す。エラー種別を UI へ伝える必要が
/// 出た段階（Phase 5 の書き出し）で throwing + `ShootLogError` へ昇格させる予定。
protocol ImageDeveloping: Sendable {

    /// 表示用の縮小プレビューを現像して返す。回転・トリミングも焼き込む（書き出しと同じ構図にする）。
    /// - Parameters:
    ///   - targetMaxPixelSize: 長辺の目標ピクセル数。0 以下・非有限を渡すとフル解像度扱い。
    ///     `cropRect` がある場合、切り抜き後の表示領域がこの解像度になるようベースデコードを拡大方向へ寄せる。
    ///   - rotation: 0 / 90 / 180 / 270（時計回り）。
    ///   - cropRect: 回転適用後の表示画像を基準にした正規化矩形（左上原点・0...1）。`nil` でトリミングなし。
    ///   - previewColorSpace: プレビュー CGImage の色空間。`nil` で sRGB。P3 ディスプレイでの編集時に
    ///     ディスプレイの色空間を渡すと、P3 書き出しと画面の見えが一致する。作業空間（linearSRGB）は不変。
    ///   - useRAWParameterMapping: RAW のとき露出・WB を `CIRAWFilter` 側へ委譲するか
    ///     （`DevelopSettings.schemaVersion` >= 2）。非 RAW では無視される。
    ///   - usesManualLensCorrection: schemaVersion の世代判定と RAW プロファイル補正との二重適用回避を
    ///     呼び出し側で織り込んだ、手動レンズ補正の最終適用可否。
    ///   - usesToneMaskedColorGrading: カラーグレーディングへトーン域マスク方式を使うか。
    ///   - asShotWhiteBalance: 非 RAW の Custom / Auto 補正の基準に使う撮影時ホワイトバランス。
    func renderPreview(
        url: URL,
        parameters: DevelopParameters,
        targetMaxPixelSize: CGFloat,
        rotation: Int,
        cropRect: CGRect?,
        previewColorSpace: CGColorSpace?,
        useRAWParameterMapping: Bool,
        usesManualLensCorrection: Bool,
        usesToneMaskedColorGrading: Bool,
        asShotWhiteBalance: WhiteBalanceSample?
    ) async -> CGImage?

    /// 書き出し用にフル解像度で現像して返す。`EditInfo` 由来の回転・トリミングもここで焼き込む。
    /// - Parameters:
    ///   - rotation: 0 / 90 / 180 / 270（時計回り）。
    ///   - cropRect: **回転適用後に表示されている画像**を基準にした正規化トリミング矩形
    ///     （左上原点・0...1）。`nil` でトリミングなし。`CropViewModel.normalizedRect` と同じ基準。
    ///   - outputColorSpace: 出力の色空間。`nil` で sRGB。作業空間（linearSRGB）は変えず、実体化時にのみ変換する。
    ///   - useRAWParameterMapping: RAW のとき露出・WB を `CIRAWFilter` 側へ委譲するか。
    ///   - usesManualLensCorrection: schemaVersion の世代判定と RAW プロファイル補正との二重適用回避を
    ///     呼び出し側で織り込んだ、手動レンズ補正の最終適用可否。
    ///   - usesToneMaskedColorGrading: カラーグレーディングへトーン域マスク方式を使うか。
    ///   - asShotWhiteBalance: 非 RAW の Custom / Auto 補正の基準に使う撮影時ホワイトバランス。
    func renderFull(
        url: URL,
        parameters: DevelopParameters,
        rotation: Int,
        cropRect: CGRect?,
        outputColorSpace: CGColorSpace?,
        useRAWParameterMapping: Bool,
        usesManualLensCorrection: Bool,
        usesToneMaskedColorGrading: Bool,
        asShotWhiteBalance: WhiteBalanceSample?
    ) async -> CGImage?

    /// 拡張子から RAW かどうかを判定する。
    func isRAW(url: URL) -> Bool

    /// 撮影時ホワイトバランス（RAW は `CIRAWFilter` の as-shot 実測、非 RAW は推定）。取得不能なら `nil`。
    func asShotNeutral(for url: URL) async -> WhiteBalanceSample?
}

extension ImageDeveloping {
    func asShotNeutral(for url: URL) async -> WhiteBalanceSample? { nil }
}

/// `DevelopParameters` を実ファイルへ適用して CGImage を生成するエンジン。
///
/// 実装プラン §4.2 の 2 層キャッシュのうち Stage A（高コストなベースデコード）だけを
/// 保持する。Stage B（安価なフィルタチェーン）は `DevelopPipeline` が毎回組み直すため、
/// スライダー操作中は再デコードを伴わずに再レンダーできる。
actor ImageDevelopmentEngine: ImageDeveloping {

    static let shared = ImageDevelopmentEngine()

    static let defaultBaseCacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.shootlog.app/develop-base-v1", isDirectory: true)
    }()

    // UserDefaults.integer(forKey:) は未設定時に 0 を返すため、既定値へフォールバックする。
    static let storedBaseCacheMaxBytes: Int = {
        let stored = UserDefaults.standard.integer(forKey: AppSettingsKeys.developBaseCacheMaxBytes)
        return stored > 0 ? stored : AppSettingsKeys.developBaseCacheMaxBytesDefault
    }()

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
    /// Stage A キャッシュの最大エントリ数。中立ベースはディスクにも退避するが、編集中の写真を往復しても
    /// 再読み込みを避けるため 24 件を保持する（3200px sRGB で最大およそ 650MB）。
    private static let cacheLimit = 24
    private static let asShotCacheLimit = 64

    /// ベースデコード結果のキャッシュキー。フル解像度（bucket 0）はキャッシュ対象外。
    /// `modifiedAt` を含めることで、同じパスのファイルが外部で差し替えられても
    /// 古いデコード結果を返さないようにする。`rawParamsHash` は RAW の露出・WB を
    /// `CIRAWFilter` 側へ委譲した場合にそのオフセット値を反映する（非委譲時は 0）。
    private struct BaseKey: Hashable {
        let path: String
        let sizeBucket: Int
        let modifiedAt: TimeInterval
        let rawParamsHash: Int
    }

    private var baseImageCache: [BaseKey: CGImage] = [:]
    /// `baseImageCache` のアクセス順（先頭が最古）。上限超過時の LRU 退避に使う。
    private var baseCacheOrder: [BaseKey] = []
    private let baseCacheDirectory: URL
    private let baseCacheMaxBytes: Int
    private var baseCacheWriteTasks: [UUID: Task<Void, Never>] = [:]

    private var asShotCache: [String: WhiteBalanceSample] = [:]
    private var asShotCacheOrder: [String] = []

    init(
        baseCacheDirectory: URL = ImageDevelopmentEngine.defaultBaseCacheDirectory,
        baseCacheMaxBytes: Int = ImageDevelopmentEngine.storedBaseCacheMaxBytes
    ) {
        self.baseCacheDirectory = baseCacheDirectory
        self.baseCacheMaxBytes = max(0, baseCacheMaxBytes)
    }

    // MARK: - RAW 判定

    nonisolated func isRAW(url: URL) -> Bool {
        Self.rawExtensions.contains(url.pathExtension.lowercased())
    }

    /// 撮影時ホワイトバランスを返す。RAW はデコーダーの as-shot 値を、非 RAW はメタデータまたは画像から推定する。
    func asShotNeutral(for url: URL) async -> WhiteBalanceSample? {
        let cacheKey = asShotCacheKey(for: url)
        if let cached = asShotCache[cacheKey] {
            touchAsShotCache(cacheKey)
            return cached
        }
        let isRAWImage = isRAW(url: url)
        let handle = Task.detached(priority: .userInitiated) { () -> WhiteBalanceSample? in
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            guard !Task.isCancelled, FileManager.default.fileExists(atPath: url.path) else { return nil }
            if isRAWImage {
                guard let filter = CIRAWFilter(imageURL: url) else { return nil }
                return WhiteBalanceSample(
                    temperatureKelvin: Double(filter.neutralTemperature),
                    tint: Double(filter.neutralTint),
                    isEstimated: false
                )
            }

            if let temperature = Self.colorTemperatureMetadata(for: url) {
                return WhiteBalanceSample(
                    temperatureKelvin: temperature,
                    tint: 0,
                    isEstimated: true
                )
            }

            guard let image = Self.decodeBaseSynchronously(
                url: url, maxPixelSize: 256, rawParameters: nil
            ), let settings = WhiteBalanceResolver.automaticSettings(from: image) else {
                return nil
            }
            return WhiteBalanceSample(
                temperatureKelvin: settings.temperatureKelvin,
                tint: settings.tint,
                isEstimated: true
            )
        }
        let sample = await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
        if let sample {
            storeAsShotCache(sample, for: cacheKey)
        }
        return sample
    }

    /// Apple 標準の RAW デコード経路について、UI と保存世代が参照できる最小限の識別情報を返す。
    /// DCP/LCP の解析・切り替えは扱わず、取得不能時も As Shot の通常デコードに委ねる。
    func rawDevelopmentProfile(for url: URL) -> RawDevelopmentProfile {
        guard isRAW(url: url) else {
            return RawDevelopmentProfile(
                cameraMake: nil,
                cameraModel: nil,
                decodeMethod: .imageIO,
                supportsAsShotWhiteBalance: false,
                profileIdentifier: "com.apple.imageio.embedded",
                processVersion: DevelopSettings.currentSchemaVersion,
                failureReason: "Not a RAW image"
            )
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return RawDevelopmentProfile(
                cameraMake: nil,
                cameraModel: nil,
                decodeMethod: .coreImageRAW,
                supportsAsShotWhiteBalance: false,
                profileIdentifier: "com.apple.coreimage.cirawfilter",
                processVersion: DevelopSettings.currentSchemaVersion,
                failureReason: "ImageIO metadata unavailable"
            )
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return RawDevelopmentProfile(
            cameraMake: tiff?[kCGImagePropertyTIFFMake] as? String,
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            decodeMethod: .coreImageRAW,
            supportsAsShotWhiteBalance: true,
            profileIdentifier: "com.apple.coreimage.cirawfilter",
            processVersion: DevelopSettings.currentSchemaVersion,
            failureReason: nil
        )
    }

    // MARK: - レンダリング

    func renderPreview(
        url: URL,
        parameters: DevelopParameters,
        targetMaxPixelSize: CGFloat,
        rotation: Int = 0,
        cropRect: CGRect? = nil,
        previewColorSpace: CGColorSpace? = nil,
        useRAWParameterMapping: Bool = false,
        usesManualLensCorrection: Bool = false,
        usesToneMaskedColorGrading: Bool = false,
        asShotWhiteBalance: WhiteBalanceSample? = nil
    ) async -> CGImage? {
        let raw = isRAW(url: url)
        let rawParameters = (raw && useRAWParameterMapping) ? parameters : nil
        let boundedDecodeTarget = Self.previewDecodeTarget(
            targetMaxPixelSize,
            cropRect: cropRect,
            hasRAWParameters: rawParameters != nil
        )
        guard let base = await baseImage(
            url: url, targetMaxPixelSize: boundedDecodeTarget, rawParameters: rawParameters
        ) else { return nil }
        guard !Task.isCancelled else { return nil }
        // 既定は sRGB。P3 ディスプレイ編集時のみ呼び出し側がディスプレイの色空間を渡す。
        // 作業空間（linearSRGB）と知覚ブラケットは不変、実体化時にのみ変換する（renderFull と同じ）。
        return await Self.develop(
            base: base,
            parameters: parameters,
            isRAW: raw,
            cache: pipelineCache,
            rotation: rotation,
            cropRect: cropRect,
            outputColorSpace: previewColorSpace ?? Self.defaultOutputColorSpace,
            skipExposureAndWhiteBalance: rawParameters != nil,
            applyManualLensCorrection: usesManualLensCorrection,
            usesToneMaskedColorGrading: usesToneMaskedColorGrading,
            asShotWhiteBalance: asShotWhiteBalance
        )
    }

    /// トリミング後の表示領域が `target` 相当の解像度になるよう、ベースデコードのサイズを引き上げる。
    /// 極端に小さいクロップで巨大デコードにならないよう 4 倍を上限にする。
    private static func decodeTarget(_ target: CGFloat, cropRect: CGRect?) -> CGFloat {
        guard target > 0, let cropRect,
              cropRect.width > 0, cropRect.height > 0,
              cropRect != CGRect(x: 0, y: 0, width: 1, height: 1) else {
            return target
        }
        let longestFraction = max(cropRect.width, cropRect.height)
        guard longestFraction > 0, longestFraction < 1 else { return target }
        return min(target / longestFraction, target * 4)
    }

    /// RAW 委譲時の Stage A デコードは、表示上必要な最大サイズを固定プロキシ相当へ抑える。
    static func previewDecodeTarget(
        _ target: CGFloat,
        cropRect: CGRect?,
        hasRAWParameters: Bool
    ) -> CGFloat {
        let decodeTarget = decodeTarget(target, cropRect: cropRect)
        // フル解像度書き出しは renderFull が直接 decodeBase を呼ぶため、この制限を通らない。
        return hasRAWParameters && decodeTarget > 0
            ? min(decodeTarget, CGFloat(PreviewCacheStore.shared.proxyLongEdge))
            : decodeTarget
    }

    /// フル解像度の現像結果を返す。回転・トリミングも焼き込む。
    /// フル解像度のベースはメモリを大きく食ううえ再利用機会も乏しいため、キャッシュしない。
    func renderFull(
        url: URL,
        parameters: DevelopParameters,
        rotation: Int,
        cropRect: CGRect?,
        outputColorSpace: CGColorSpace? = nil,
        useRAWParameterMapping: Bool = false,
        usesManualLensCorrection: Bool = false,
        usesToneMaskedColorGrading: Bool = false,
        asShotWhiteBalance: WhiteBalanceSample? = nil
    ) async -> CGImage? {
        let raw = isRAW(url: url)
        let rawParameters = (raw && useRAWParameterMapping) ? parameters : nil
        guard let base = await Self.decodeBase(
            url: url, maxPixelSize: 0, rawParameters: rawParameters
        ) else { return nil }
        guard !Task.isCancelled else { return nil }
        return await Self.develop(
            base: base,
            parameters: parameters,
            isRAW: raw,
            cache: pipelineCache,
            rotation: rotation,
            cropRect: cropRect,
            outputColorSpace: outputColorSpace ?? Self.defaultOutputColorSpace,
            skipExposureAndWhiteBalance: rawParameters != nil,
            applyManualLensCorrection: usesManualLensCorrection,
            usesToneMaskedColorGrading: usesToneMaskedColorGrading,
            asShotWhiteBalance: asShotWhiteBalance
        )
    }

    /// 明示指定が無いときの出力色空間。
    private static let defaultOutputColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: - Stage A（ベースデコード + キャッシュ）

    private func baseImage(
        url: URL,
        targetMaxPixelSize: CGFloat,
        rawParameters: DevelopParameters?
    ) async -> CGImage? {
        let bucket = Self.sizeBucket(for: targetMaxPixelSize)
        let rawHash = rawParameters.map { RAWDevelopMapping.decodeHash($0) } ?? 0
        let key = BaseKey(
            path: url.path,
            sizeBucket: bucket,
            modifiedAt: Self.modificationTime(of: url),
            rawParamsHash: rawHash
        )

        if bucket > 0, let cached = baseImageCache[key] {
            touch(key)
            return cached
        }

        if Self.shouldUseDiskBaseCache(bucket: bucket, rawParameters: rawParameters),
           let diskCached = await readDiskBase(for: key) {
            store(diskCached, for: key)
            return diskCached
        }

        // デコード中は actor が中断するため、同一キーの要求が重なると二重デコードになりうる。
        // 起きても結果は同じで、後勝ちでキャッシュされるだけなので、進行中タスクの共有は行わない。
        guard let decoded = await Self.decodeBase(
            url: url,
            maxPixelSize: Self.bucketPixelSize(bucket),
            rawParameters: rawParameters
        ) else {
            return nil
        }

        if bucket > 0 {
            store(decoded, for: key)
            if Self.shouldUseDiskBaseCache(bucket: bucket, rawParameters: rawParameters) {
                scheduleDiskBaseWrite(decoded, for: key)
            }
        }
        return decoded
    }

    /// 起動時に現像ベースキャッシュの中断ファイルを掃除し、容量上限まで削除する。
    func warmUpCaches() async {
        let directory = baseCacheDirectory
        let maxBytes = baseCacheMaxBytes
        await Task.detached(priority: .utility) {
            ImageFileCache.prepare(directory: directory, extensions: ["png"])
            ImageFileCache.evict(in: directory, maxBytes: maxBytes)
        }.value
    }

    /// 設定画面の「ディスクキャッシュを削除」から呼ぶ。現像ベースのメモリ・ディスク双方を空にする。
    /// 撮影時 WB のメモリキャッシュも落とす（`Photo` の永続値は消さない）。
    func clearDiskCaches() async {
        baseImageCache.removeAll()
        baseCacheOrder.removeAll()
        asShotCache.removeAll()
        asShotCacheOrder.removeAll()
        let directory = baseCacheDirectory
        await Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { return }
            for file in files { try? FileManager.default.removeItem(at: file) }
        }.value
    }

    /// テストが非同期ディスク書き込みの完了を待つためのフック。
    func waitForBaseCacheWritesForTesting() async {
        let tasks = Array(baseCacheWriteTasks.values)
        for task in tasks {
            await task.value
        }
    }

    func asShotCacheCountForTesting() -> Int {
        asShotCache.count
    }

    private func readDiskBase(for key: BaseKey) async -> CGImage? {
        let directory = baseCacheDirectory
        let diskKey = Self.diskKey(for: key)
        let task: Task<CGImage?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return ImageFileCache.read(forKey: diskKey, extensions: ["png"], in: directory)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func scheduleDiskBaseWrite(_ image: CGImage, for key: BaseKey) {
        let id = UUID()
        let directory = baseCacheDirectory
        let maxBytes = baseCacheMaxBytes
        let diskKey = Self.diskKey(for: key)
        let engine = self
        let task = Task.detached(priority: .utility) {
            defer {
                Task { await engine.finishBaseCacheWrite(id) }
            }
            guard !Task.isCancelled else { return }
            ImageFileCache.prepare(directory: directory, extensions: ["png"])
            guard ImageFileCache.write(
                image,
                type: "public.png" as CFString,
                to: ImageFileCache.fileURL(forKey: diskKey, extension: "png", in: directory)
            ) else { return }
            ImageFileCache.evict(in: directory, maxBytes: maxBytes)
        }
        baseCacheWriteTasks[id] = task
    }

    private func finishBaseCacheWrite(_ id: UUID) {
        baseCacheWriteTasks.removeValue(forKey: id)
    }

    private func store(_ image: CGImage, for key: BaseKey) {
        if baseImageCache[key] == nil {
            while baseImageCache.count >= Self.cacheLimit, let victim = baseCacheOrder.first {
                baseCacheOrder.removeFirst()
                baseImageCache.removeValue(forKey: victim)
            }
        }
        baseImageCache[key] = image
        touch(key)
    }

    /// キャッシュヒット / 追加したキーをアクセス順の末尾（最新）へ動かす。
    private func touch(_ key: BaseKey) {
        if let index = baseCacheOrder.firstIndex(of: key) {
            baseCacheOrder.remove(at: index)
        }
        baseCacheOrder.append(key)
    }

    private func asShotCacheKey(for url: URL) -> String {
        "\(url.path)|\(Self.modificationTime(of: url))"
    }

    private func storeAsShotCache(_ sample: WhiteBalanceSample, for key: String) {
        if asShotCache[key] == nil {
            while asShotCache.count >= Self.asShotCacheLimit, let victim = asShotCacheOrder.first {
                asShotCacheOrder.removeFirst()
                asShotCache.removeValue(forKey: victim)
            }
        }
        asShotCache[key] = sample
        touchAsShotCache(key)
    }

    private func touchAsShotCache(_ key: String) {
        if let index = asShotCacheOrder.firstIndex(of: key) {
            asShotCacheOrder.remove(at: index)
        }
        asShotCacheOrder.append(key)
    }

    private static func diskKey(for key: BaseKey) -> String {
        let source = "\(key.path)|\(key.modifiedAt)|\(key.sizeBucket)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func shouldUseDiskBaseCache(bucket: Int, rawParameters: DevelopParameters?) -> Bool {
        bucket > 0 && rawParameters == nil
    }

    /// 原本の最終更新時刻（参照日時基準の秒）。取得できなければ 0。
    /// キャッシュキーに含め、ファイル差し替え後に stale なデコード結果を返さないようにする。
    /// `URL.resourceValues` は URL 側に値をキャッシュしうるため、毎回 stat し直す `FileManager` を使う。
    private static func modificationTime(of url: URL) -> TimeInterval {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return date?.timeIntervalSinceReferenceDate ?? 0
    }

    /// 非 RAW に保存されることがある色温度メタデータをベストエフォートで読む。
    private static func colorTemperatureMetadata(for url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let temperature = validColorTemperature(exif["ColorTemperature" as CFString]) {
            return temperature
        }

        for dictionaryKey in [kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary] {
            if let temperature = colorTemperature(in: properties[dictionaryKey]) {
                return temperature
            }
        }
        return nil
    }

    /// MakerNote のキーはカメラごとに異なるため、色温度を示す名前の有限な数値だけを採用する。
    private static func colorTemperature(in value: Any?) -> Double? {
        guard let dictionary = value as? [CFString: Any] else { return nil }
        for key in dictionary.keys.sorted(by: { ($0 as String) < ($1 as String) }) {
            guard let nestedValue = dictionary[key] else { continue }
            let keyName = key as String
            if keyName.localizedCaseInsensitiveContains("colorTemperature"),
               let temperature = validColorTemperature(nestedValue) {
                return temperature
            }
            if let temperature = colorTemperature(in: nestedValue) {
                return temperature
            }
        }
        return nil
    }

    private static func validColorTemperature(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let temperature = number.doubleValue
        guard temperature.isFinite, (1_000...50_000).contains(temperature) else { return nil }
        return temperature
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
    private static func decodeBase(
        url: URL,
        maxPixelSize: CGFloat,
        rawParameters: DevelopParameters?
    ) async -> CGImage? {
        let handle = Task.detached(priority: .userInitiated) { () -> CGImage? in
            // ブックマーク復元 URL に対してセキュリティスコープを要求する（通常 URL では no-op）
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            guard !Task.isCancelled else { return nil }
            return Self.decodeBaseSynchronously(
                url: url, maxPixelSize: maxPixelSize, rawParameters: rawParameters
            )
        }
        return await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    private static func decodeBaseSynchronously(
        url: URL,
        maxPixelSize: CGFloat,
        rawParameters: DevelopParameters?
    ) -> CGImage? {
        let treatAsRAW = rawExtensions.contains(url.pathExtension.lowercased())

        var source: CIImage?
        if treatAsRAW {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            // 露出・WB を委譲する場合のみ CIRAWFilter のパラメータを触る。それ以外は as-shot 既定。
            if let rawParameters {
                RAWDevelopMapping.apply(rawParameters, to: filter)
            }
            // RAW は scaleFactor を先に指定すると縮小デコードになり、後段の縮小より大幅に速い。
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
        cache: DevelopPipelineCache,
        rotation: Int,
        cropRect: CGRect?,
        outputColorSpace: CGColorSpace,
        skipExposureAndWhiteBalance: Bool,
        applyManualLensCorrection: Bool,
        usesToneMaskedColorGrading: Bool,
        asShotWhiteBalance: WhiteBalanceSample?
    ) async -> CGImage? {
        let handle = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            let source = CIImage(cgImage: base)
            var image = DevelopPipeline.apply(
                parameters, to: source, isRAW: isRAW, cache: cache,
                skipExposureAndWhiteBalance: skipExposureAndWhiteBalance,
                applyManualLensCorrection: applyManualLensCorrection,
                usesToneMaskedColorGrading: usesToneMaskedColorGrading,
                asShotWhiteBalance: asShotWhiteBalance
            )
            // 回転 → トリミングの順。cropRect は「回転後に表示されている画像」基準の正規化矩形なので、
            // 先に回転を焼き込んでから同じ割合で切り抜くと、ユーザーが画面で見た構図と一致する。
            image = applyRotation(rotation, to: image)
            image = applyCrop(cropRect, to: image)
            guard !Task.isCancelled else { return nil }

            let rect = image.extent.integral
            guard !rect.isEmpty, !rect.isInfinite else { return nil }
            // 作業空間（linearSRGB）から指定の出力空間へ変換して実体化する。
            return sharedContext.createCGImage(
                image, from: rect, format: .RGBA8, colorSpace: outputColorSpace
            )
        }
        return await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    /// 正規化トリミング矩形（左上原点、回転後の画像基準）を CIImage の座標系（左下原点）へ
    /// 変換して切り抜く。`applyRotation` の後に呼ぶこと（`image` が回転済みである前提）。
    private static func applyCrop(_ cropRect: CGRect?, to image: CIImage) -> CIImage {
        guard let cropRect,
              cropRect != CGRect(x: 0, y: 0, width: 1, height: 1),
              cropRect.width > 0, cropRect.height > 0 else {
            return image
        }
        let extent = image.extent
        let pixelRect = CGRect(
            x: extent.minX + cropRect.minX * extent.width,
            y: extent.minY + (1 - cropRect.maxY) * extent.height,
            width: cropRect.width * extent.width,
            height: cropRect.height * extent.height
        ).integral
        let cropped = image.cropped(to: pixelRect)
        // 切り抜き後は原点を 0 に寄せてエンコード時の座標ずれを防ぐ
        return cropped.transformed(by: CGAffineTransform(translationX: -pixelRect.minX, y: -pixelRect.minY))
    }

    /// 時計回りの回転角（0/90/180/270）を EXIF オリエンテーション経由で適用する。
    private static func applyRotation(_ rotation: Int, to image: CIImage) -> CIImage {
        let normalized = ((rotation % 360) + 360) % 360
        let orientation: CGImagePropertyOrientation?
        switch normalized {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: orientation = nil
        }
        guard let orientation else { return image }
        let oriented = image.oriented(orientation)
        return oriented.transformed(
            by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY)
        )
    }
}
