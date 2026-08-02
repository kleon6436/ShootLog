import AppKit
import CryptoKit
import ImageIO

// サムネイルの取得・メモリキャッシュ・ディスクキャッシュを担当するサービス
// ネットワークドライブ対応：埋め込みサムネイル優先＋ディスクキャッシュ＋同時実行スロット
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
        try? FileManager.default.createDirectory(at: Self.diskCacheDir, withIntermediateDirectories: true)
    }

    // NSCache はスレッドセーフ。nonisolated(unsafe) で Swift 6 の Sendable チェックを回避する
    nonisolated(unsafe) private let memoryCache = NSCache<NSURL, NSImage>()
    nonisolated(unsafe) private let highResCache = NSCache<NSURL, NSImage>()

    // ネットワークドライブ向け：同時サムネイル取得数を制限するスロット。
    // 件数は「一般」設定タブの値（未設定時は 0 が返るため既定値 4 件へフォールバック）
    private let throttle: ThumbnailThrottle = {
        let stored = UserDefaults.standard.integer(forKey: AppSettingsKeys.networkConcurrency)
        return ThumbnailThrottle(maxConcurrent: stored > 0 ? stored : AppSettingsKeys.networkConcurrencyDefault)
    }()

    // サムネイルの最大ピクセルサイズ。既定の768pxは、グリッドセル最大240pt(Retina 2倍=480px)の
    // 横長box(3:2)に縦位置写真をfillクロップ表示しても短辺が480pxを下回らないための値
    // (768 × 2/3 ≈ 512 > 480、余裕を持たせて768に設定)
    private let thumbnailMaxPixelSize: Int

    // 埋め込みプレビューをそのまま採用してよい最小サイズ（これ未満はフルデコードへフォールバック）
    private let minAcceptablePixelSize: Int

    // ボリューム→ネットワーク判定のキャッシュ（セッション中に変わらない前提）
    nonisolated(unsafe) private let volumeCache = NSCache<NSURL, NSNumber>()

    // MARK: - Public

    // 指定 URL のサムネイルを返す（メモリ→ディスク→ImageIO の順で確認）
    func thumbnail(for url: URL) async -> NSImage? {
        let key = url as NSURL

        // 1. メモリキャッシュ
        if let img = memoryCache.object(forKey: key) { return img }

        // 2. ディスクキャッシュ（再起動後もネットワーク読み込みを回避できる）
        let diskURL = Self.diskCacheURL(for: url)
        if let img = NSImage(contentsOf: diskURL) {
            memoryCache.setObject(img, forKey: key)
            return img
        }

        // 3. ネットワークドライブのみスロットを確保して並列 I/O を抑制する
        let isNetwork = volumeIsNetwork(url)
        if isNetwork {
            do {
                try await throttle.acquire()
            } catch {
                // 待機中にセルが画面外へスクロールされキャンセルされた：スロットは未取得なので release 不要
                return nil
            }
        }

        // スロット取得後にキャンセルされていた場合、I/Oを始めずに即座にスロットを返す
        guard !Task.isCancelled else {
            if isNetwork { await throttle.release() }
            return nil
        }

        let cgImage = await Task.detached(priority: .utility) {
            self.loadCGThumbnail(from: url)
        }.value

        // スロット解放は I/O 完了直後（NSImage 生成・キャッシュ書き込みの前）
        if isNetwork { await throttle.release() }
        guard let cgImage else { return nil }

        let image = NSImage(cgImage: cgImage, size: .zero)
        memoryCache.setObject(image, forKey: key)

        // 4. ディスクキャッシュへ書き込む（バックグラウンドで非同期）
        Task.detached(priority: .background) {
            Self.writeDiskCache(cgImage: cgImage, to: diskURL)
        }
        return image
    }

    // メインビューア用：フルサイズ画像を返す（メモリ→CGImageSource の順で確認）
    // NSImage(contentsOf:) は RAW ファイルで埋め込み JPEG プレビューを返す場合があるため、
    // CGImageSourceCreateImageAtIndex でフルセンサー解像度を明示的に取得する
    func highResImage(for url: URL) async -> NSImage? {
        let key = url as NSURL

        if let img = highResCache.object(forKey: key) { return img }

        let isNetwork = volumeIsNetwork(url)
        if isNetwork {
            do {
                try await throttle.acquire()
            } catch {
                // 待機中にキャンセルされた：スロットは未取得なので release 不要
                return nil
            }
        }

        guard !Task.isCancelled else {
            if isNetwork { await throttle.release() }
            return nil
        }

        let image = await Task.detached(priority: .utility) {
            // ブックマーク復元 URL に対してセキュリティスコープを要求する（通常 URL では no-op）
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            // kCGImageSourceShouldCacheImmediately: false でデコード前のメモリ確保を抑制する
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil as NSImage? }

            // size: .zero で NSImage が CGImage のピクセル寸法を 1pt=1px として採用する
            return NSImage(cgImage: cgImage, size: .zero)
        }.value

        if isNetwork { await throttle.release() }
        guard let image else { return nil }

        highResCache.setObject(image, forKey: key)
        return image
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

    // URLが属するボリュームのネットワーク判定（ボリューム単位でキャッシュ）
    private func volumeIsNetwork(_ url: URL) -> Bool {
        let volumeURL = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? url
        let cacheKey = volumeURL as NSURL
        if let cached = volumeCache.object(forKey: cacheKey) { return cached.boolValue }
        let isLocal = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        let isNetwork = !isLocal
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

// MARK: - ネットワークドライブ用同時実行スロット

// 同時サムネイル取得数を制限するアクター
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
