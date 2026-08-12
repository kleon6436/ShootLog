import AppKit
import CryptoKit
import ImageIO

// サムネイル・高解像度画像の取得、メモリキャッシュ・ディスクキャッシュを担当するサービス
// ネットワークドライブ対応：埋め込みプレビュー優先＋ディスクキャッシュ＋同時実行スロット（ネットワーク／ローカル別）
final class ImageLoader: Sendable {
    static let shared = ImageLoader()
    // 起動時に ShootLogApp からMainActor外でウォームアップされる前提（MainActor上でのディスクI/Oを回避）
    // 「一般」設定タブの画質設定はここで一度だけ読み込む（設定変更は次回起動から反映される）
    private init() {
        let storedQuality = UserDefaults.standard.integer(forKey: AppSettingsKeys.thumbnailQuality)
        let maxPixelSize = ThumbnailQuality(rawValue: storedQuality)?.rawValue
            ?? ThumbnailQuality.standard.rawValue
        thumbnailMaxPixelSize = maxPixelSize
        minAcceptablePixelSize = maxPixelSize * 3 / 4
    }

    // NSCache はスレッドセーフ。nonisolated(unsafe) で Swift 6 の Sendable チェックを回避する
    // totalCostLimit はデコード後の概算バイト数（ピクセル数 × 4）を単位とする（estimatedCost(of:) 参照）
    nonisolated(unsafe) private let memoryCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = Limits.thumbnailCount
        cache.totalCostLimit = Limits.thumbnailTotalCost
        return cache
    }()
    // 高解像度画像は目標ピクセルサイズごとにキャッシュするため、URLとサイズを組み合わせた文字列をキーにする
    nonisolated(unsafe) private let highResCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = Limits.highResCount
        cache.totalCostLimit = Limits.highResTotalCost
        return cache
    }()

    // キャッシュ上限。前後1枚の先読みを含めても数枚分は確実に残る値を設定する
    private enum Limits {
        // サムネイル（最大768px ≒ 2.4MB/枚）。192MBのコスト上限が先に効いて実効約80枚となるため、
        // 件数上限は極端に小さいサムネイルが大量に載った場合の安全弁として働く
        static let thumbnailCount = 100
        static let thumbnailTotalCost = 192 * 1024 * 1024
        // 高解像度画像（既定3000px ≒ 24MB/枚）。現在＋前後1枚に加え、往復移動分の余裕を持たせる
        static let highResCount = 8
        static let highResTotalCost = 320 * 1024 * 1024
        // ボリューム判定（NSNumber）はごく小さいためコスト上限は設けず件数のみ制限する
        static let volumeCount = 64
    }

    // ネットワークドライブ向け：同時サムネイル取得数を制限するスロット。
    // 件数は「一般」設定タブの値（未設定時は 0 が返るため既定値 4 件へフォールバック）
    private let networkThrottle: ThumbnailThrottle = {
        let stored = UserDefaults.standard.integer(forKey: AppSettingsKeys.networkConcurrency)
        return ThumbnailThrottle(maxConcurrent: stored > 0 ? stored : AppSettingsKeys.networkConcurrencyDefault)
    }()

    // ローカルボリューム向け：RAWデコードはCPU負荷が高く、コア数を超える同時実行は
    // コンテキストスイッチで逆に遅くなるため、コア数を上限としてスロットを設ける
    private let localThrottle = ThumbnailThrottle(maxConcurrent: max(2, ProcessInfo.processInfo.activeProcessorCount))

    // 指定URLのボリューム種別に応じたスロットを返す
    private func throttle(for url: URL) -> ThumbnailThrottle {
        volumeIsNetwork(url) ? networkThrottle : localThrottle
    }

    // サムネイルの最大ピクセルサイズ。既定の768pxは、グリッドセル最大240pt(Retina 2倍=480px)の
    // 横長box(3:2)に縦位置写真をfillクロップ表示しても短辺が480pxを下回らないための値
    // (768 × 2/3 ≈ 512 > 480、余裕を持たせて768に設定)
    private let thumbnailMaxPixelSize: Int

    // 埋め込みプレビューをそのまま採用してよい最小サイズ（これ未満はフルデコードへフォールバック）
    private let minAcceptablePixelSize: Int

    // ボリューム→ネットワーク判定のキャッシュ（セッション中に変わらない前提）
    nonisolated(unsafe) private let volumeCache: NSCache<NSURL, NSNumber> = {
        let cache = NSCache<NSURL, NSNumber>()
        cache.countLimit = Limits.volumeCount
        return cache
    }()

    // MARK: - 高解像度画像の目標ピクセルサイズ

    // 表示領域サイズが指定されなかった場合に使う既定の目標ピクセルサイズ。
    // フルサイズより十分小さくメモリを抑えつつ、Retinaの全画面表示でも劣化を感じにくい値
    static let defaultHighResMaxPixelSize: CGFloat = 3000

    // ダウンサンプルを行わずフルサイズでデコードさせるための指定値（最大ズーム時のフォールバック用）
    static let fullSizePixelTarget: CGFloat = 0

    // 目標ピクセルサイズの量子化ステップ。ズーム操作で目標値が細かく変動しても
    // 同一バケットに落ちる限り再デコードとキャッシュ増殖を避けられる
    private static let highResBucketStep = 512

    // このサイズを超える要求はダウンサンプルの意味が薄いためフルサイズデコードへ回す
    private static let highResBucketCeiling = 8192

    // MARK: - Public

    // 指定 URL のサムネイルを返す（メモリ→ディスク→ImageIO の順で確認）
    func thumbnail(for url: URL) async -> NSImage? {
        let key = url as NSURL

        // 1. メモリキャッシュ
        if let img = memoryCache.object(forKey: key) { return img }

        // 2. ディスクキャッシュ（再起動後もネットワーク読み込みを回避できる）
        // このメソッドは ImageLoader が @MainActor を持たないため nonisolated async として実行され、
        // 呼び出し元が @MainActor（PhotoThumbnailViewModel / PhotoImageViewModel）でも
        // 本体はMainActorを離れて動く。同期I/OがMainActorを塞ぐ経路は無い
        let diskURL = Self.diskCacheURL(for: url)
        if let img = NSImage(contentsOf: diskURL) {
            memoryCache.setObject(img, forKey: key, cost: Self.estimatedCost(of: img))
            return img
        }

        // 3. 同時デコード数を制限するスロットを確保する（ネットワーク／ローカルで別スロット）
        let activeThrottle = throttle(for: url)
        do {
            try await activeThrottle.acquire()
        } catch {
            // 待機中にセルが画面外へスクロールされキャンセルされた：スロットは未取得なので release 不要
            return nil
        }

        // スロット取得後にキャンセルされていた場合、I/Oを始めずに即座にスロットを返す
        guard !Task.isCancelled else {
            await activeThrottle.release()
            return nil
        }

        let cgImage = await Task.detached(priority: .utility) {
            self.loadCGThumbnail(from: url)
        }.value

        // スロット解放は I/O 完了直後（NSImage 生成・キャッシュ書き込みの前）
        await activeThrottle.release()
        guard let cgImage else { return nil }

        let image = NSImage(cgImage: cgImage, size: .zero)
        memoryCache.setObject(image, forKey: key, cost: cgImage.width * cgImage.height * 4)

        // 4. ディスクキャッシュへ書き込む（バックグラウンドで非同期）
        Task.detached(priority: .background) {
            Self.writeDiskCache(cgImage: cgImage, to: diskURL)
        }
        return image
    }

    // メインビューア用：表示領域に合わせてダウンサンプルした高解像度画像を返す（メモリ→CGImageSource の順で確認）
    // NSImage(contentsOf:) は RAW ファイルで埋め込み JPEG プレビューを返す場合があるため、
    // CGImageSource 経由で必要な解像度を明示的に取得する
    //
    // targetMaxPixelSize には表示領域の長辺ピクセル数（ビューサイズ × 画面スケール）を渡す。
    // RAW のセンサー解像度をそのままデコードしないことでメモリピークとデコード時間を抑える。
    // fullSizePixelTarget を渡した場合のみ従来どおりフルサイズをデコードする（最大ズーム時のフォールバック）。
    //
    // 注意：ズーム操作中は目標サイズが連続的に変化するため、呼び出し側で
    // ズーム完了時のみ再要求するデバウンスを行うこと（バケット量子化でも再デコードは完全には防げない）。
    func highResImage(
        for url: URL,
        targetMaxPixelSize: CGFloat = ImageLoader.defaultHighResMaxPixelSize
    ) async -> NSImage? {
        let bucket = Self.pixelBucket(for: targetMaxPixelSize)
        let key = Self.highResCacheKey(for: url, bucket: bucket)

        if let img = highResCache.object(forKey: key) { return img }

        let activeThrottle = throttle(for: url)
        do {
            try await activeThrottle.acquire()
        } catch {
            // 待機中にキャンセルされた：スロットは未取得なので release 不要
            return nil
        }

        guard !Task.isCancelled else {
            await activeThrottle.release()
            return nil
        }

        let image = await Task.detached(priority: .userInitiated) {
            // ブックマーク復元 URL に対してセキュリティスコープを要求する（通常 URL では no-op）
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            // kCGImageSourceShouldCacheImmediately: false でデコード前のメモリ確保を抑制する
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return nil as NSImage?
            }

            let cgImage: CGImage? = bucket > 0
                ? Self.decodeDownsampled(source: source, bucket: bucket)
                : CGImageSourceCreateImageAtIndex(source, 0, nil)
            guard let cgImage else { return nil as NSImage? }

            // size: .zero で NSImage が CGImage のピクセル寸法を 1pt=1px として採用する
            return NSImage(cgImage: cgImage, size: .zero)
        }.value

        await activeThrottle.release()
        guard let image else { return nil }

        highResCache.setObject(image, forKey: key, cost: Self.estimatedCost(of: image))
        return image
    }

    // 表示領域に合わせたダウンサンプルデコード（同期・バックグラウンド用）。
    // RAW は埋め込みプレビューがあれば優先し、センサー解像度からのフルデコードを避ける。
    // 埋め込みプレビューが目標サイズの90%未満（引き伸ばしで劣化が出る）の場合のみ
    // 元画像からのダウンサンプルへフォールバックする。
    // kCGImageSourceCreateThumbnailWithTransform は両経路とも指定しない（従来のフルサイズ経路と
    // 向きの扱いを揃え、サムネイル→高解像度の差し替えで挙動を変えないため）
    private static let embeddedPreviewMinRatio: CGFloat = 0.9

    private static func decodeDownsampled(source: CGImageSource, bucket: Int) -> CGImage? {
        let embeddedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
            kCGImageSourceShouldCacheImmediately: false
        ]
        if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions as CFDictionary),
           CGFloat(max(embedded.width, embedded.height)) >= CGFloat(bucket) * embeddedPreviewMinRatio {
            return embedded
        }

        // 埋め込みプレビューが無い、または解像度不足：元画像からダウンサンプル
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary)
    }

    // メモリキャッシュとディスクキャッシュを削除する。
    // 設定画面からのユーザーの明示操作でのみ呼ぶ（通常操作では呼ばない）。
    // 部分的な削除失敗は致命的ではないため try? で無視し、次回表示時に再生成させる
    func clearDiskCache() {
        memoryCache.removeAllObjects()
        highResCache.removeAllObjects()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.diskCacheDir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Private

    // 目標ピクセルサイズを量子化する。0 はフルサイズデコードを表す
    // （fullSizePixelTarget や NaN・無限大・負値も guard でここに落ちる）
    private static func pixelBucket(for target: CGFloat) -> Int {
        guard target > 0, target.isFinite else { return 0 }
        let step = CGFloat(highResBucketStep)
        // Int 変換前に上限直上でクランプする。異常に大きい表示サイズが渡されても
        // Int(_:) が representable range 外でトラップしない。クランプ後の値は必ず
        // highResBucketCeiling を上回るため、最終的にフルサイズ経路（0）へ落ちる
        let clamped = min(max(target, step), CGFloat(highResBucketCeiling) + step)
        let bucket = Int((clamped / step).rounded(.up)) * highResBucketStep
        return bucket > highResBucketCeiling ? 0 : bucket
    }

    // 同一URLでも目標サイズごとに別エントリとして扱うためのキャッシュキー
    private static func highResCacheKey(for url: URL, bucket: Int) -> NSString {
        "\(bucket)|\(url.absoluteString)" as NSString
    }

    // デコード後の概算メモリコスト（ピクセル数 × 4バイト）。NSCache の totalCostLimit に渡す
    private static func estimatedCost(of image: NSImage) -> Int {
        let rep = image.representations.first
        let width = rep?.pixelsWide ?? Int(image.size.width)
        let height = rep?.pixelsHigh ?? Int(image.size.height)
        return max(1, width * height * 4)
    }

    // URLが属するボリュームのネットワーク判定（ボリューム単位でキャッシュ）
    private func volumeIsNetwork(_ url: URL) -> Bool {
        let volumeURL = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? url
        let cacheKey = volumeURL as NSURL
        if let cached = volumeCache.object(forKey: cacheKey) { return cached.boolValue }
        let isNetwork = url.isOnNetworkVolume
        volumeCache.setObject(NSNumber(value: isNetwork), forKey: cacheKey)
        return isNetwork
    }

    // 埋め込みサムネイルを優先して CGImage を生成する（同期・バックグラウンド用）
    // RAW ファイルは埋め込み JPEG を持つため、フルサイズデコードより転送量を大幅削減できる
    private func loadCGThumbnail(from url: URL) -> CGImage? {
        // ブックマーク復元 URL に対してセキュリティスコープを要求する（通常 URL では no-op）
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        let sourceOpts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOpts as CFDictionary) else { return nil }

        // 埋め込みサムネイルを優先（IfAbsent = 埋め込みがあればそれを使い、なければスキップ）
        // 注意：埋め込みプレビューが thumbnailMaxPixelSize より小さい場合、ImageIOは
        // アップスケールせず「小さいまま」返す（サイドバーで引き伸ばされてぼやける原因）。
        // そのためサイズ不足時はフォールバックのフルサイズデコードへ回す。
        let embeddedOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        if let img = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOpts as CFDictionary),
           max(img.width, img.height) >= minAcceptablePixelSize {
            return img
        }

        // フォールバック：フルサイズからデコード
        let fullOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, fullOpts as CFDictionary)
    }

    // URL の SHA256 ハッシュをファイル名にしたディスクキャッシュ URL
    private static func diskCacheURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return diskCacheDir.appendingPathComponent(hash).appendingPathExtension("png")
    }

    private static func writeDiskCache(cgImage: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    // ~/Library/Caches/com.shootlog.app/thumbnails-v4/
    // （v4=埋め込みプレビューが小さすぎる場合のフルデコードフォールバックを追加、v3までのぼやけキャッシュを無効化）
    static let diskCacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.shootlog.app/thumbnails-v4", isDirectory: true)
    }()
}

// MARK: - 同時実行スロット

// 同時デコード数を制限するアクター（ネットワーク用・ローカル用それぞれ別インスタンスを持つ）
// acquire で空きがなければ待機し、release で次の待機タスクを起こす
//
// キャンセル対応が必須の理由：素の withCheckedContinuation はタスクキャンセルを無視するため、
// 高速スクロールでセルが画面外に流れて .task がキャンセルされても、
// スロット待ちの継続だけがキューに残り続け、実際に表示中のセルの順番を塞いでしまう
// （スクロールし切った場所のサムネイルがいつまでも読み込まれない不具合の原因）
private actor ThumbnailThrottle {
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    // スロット取得：空きがなければ resume されるまでサスペンド。
    // 待機中にタスクがキャンセルされた場合は CancellationError を投げて即座にキューから離脱する
    func acquire() async throws {
        guard active >= maxConcurrent else { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    // キャンセルされた待機者をキューから取り除く（スロットは消費していないので active は変更しない）
    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    // スロット解放：待機中タスクがあればスロットを転送、なければデクリメント
    func release() {
        if let (id, continuation) = waiters.first {
            waiters.removeValue(forKey: id)
            continuation.resume()
        } else {
            active -= 1
        }
    }
}
