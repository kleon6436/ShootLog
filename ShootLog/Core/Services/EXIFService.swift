import Foundation
import ImageIO

// ImageIO を使って EXIF 情報を非同期で読み取るサービス
actor EXIFService {
    static let shared = EXIFService()
    private init() {}

    // 分析画面の一括取得で同時に走らせる読み取り数の上限（ローカルボリューム）。
    // 無制限にすると I/O 競合でかえって遅くなるため上限を設ける
    static let defaultBatchConcurrency = 6

    // 一括取得の同時実行数を決める。ネットワークボリューム上の写真では
    // サムネイル取得（ImageLoader の ThumbnailThrottle）と同じ「一般」設定タブの値へ揃え、
    // 同時 I/O 本数が過剰にならないようにする（未設定時は 0 が返るため既定値へフォールバック）
    nonisolated static func recommendedBatchConcurrency(for url: URL?) -> Int {
        guard let url, url.isOnNetworkVolume else { return defaultBatchConcurrency }
        let stored = UserDefaults.standard.integer(forKey: AppSettingsKeys.networkConcurrency)
        return stored > 0 ? stored : AppSettingsKeys.networkConcurrencyDefault
    }

    // DateFormatter は macOS 10.9 以降、生成後に設定を変更しなければ複数スレッドからの
    // 読み取りが安全なため、並列読み取りから共有できる定数として保持する
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        // EXIF規格固定のフォーマットを解釈するため、暦や数字がユーザーのロケール設定に
        // 引きずられないよう en_US_POSIX を指定する。
        // タイムZone は EXIF が撮影地のローカル時刻を持つ仕様のため、あえて設定しない
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    // 指定 URL の写真から EXIF を読み取る。バックグラウンドスレッドで呼ぶこと
    func readEXIF(from url: URL) throws -> EXIFInfo {
        try Self.parseEXIF(from: url)
    }

    // 複数 URL の EXIF を並列に読み取る。actor のシリアル実行を避けるため nonisolated とし、
    // 同時実行数は maxConcurrency で制限する。読み取りに失敗した URL は結果に含めない
    nonisolated func readEXIFBatch(
        from urls: [URL],
        maxConcurrency: Int = EXIFService.defaultBatchConcurrency
    ) async -> [URL: EXIFInfo] {
        guard !urls.isEmpty else { return [:] }
        let limit = max(1, min(maxConcurrency, urls.count))

        return await withTaskGroup(of: (URL, EXIFInfo)?.self) { group in
            var results: [URL: EXIFInfo] = [:]
            results.reserveCapacity(urls.count)
            var nextIndex = 0

            func addTask(for url: URL) {
                group.addTask(priority: .utility) {
                    // 実行開始前にキャンセルを検査し、cancelAll() 後に未着手の子タスクが走らないようにする
                    guard !Task.isCancelled, let exif = try? Self.parseEXIF(from: url) else { return nil }
                    return (url, exif)
                }
            }

            while nextIndex < limit {
                addTask(for: urls[nextIndex])
                nextIndex += 1
            }

            while let finished = await group.next() {
                if let (url, exif) = finished { results[url] = exif }
                if Task.isCancelled { break }
                if nextIndex < urls.count {
                    addTask(for: urls[nextIndex])
                    nextIndex += 1
                }
            }

            group.cancelAll()
            return results
        }
    }

    // MARK: - Parsing

    // ImageIO による EXIF 読み取り本体。並列実行できるよう actor 分離から切り離している
    nonisolated private static func parseEXIF(from url: URL) throws -> EXIFInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ShootLogError.exifReadFailed
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif  = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff  = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        return EXIFInfo(
            cameraMake:    tiff[kCGImagePropertyTIFFMake]              as? String,
            cameraModel:   tiff[kCGImagePropertyTIFFModel]             as? String,
            lensModel:     exif[kCGImagePropertyExifLensModel]         as? String,
            aperture:      exif[kCGImagePropertyExifFNumber]           as? Double,
            shutterSpeed:  exif[kCGImagePropertyExifExposureTime]      as? Double,
            iso:           (exif[kCGImagePropertyExifISOSpeedRatings]  as? [Int])?.first,
            focalLength:   exif[kCGImagePropertyExifFocalLength]       as? Double,
            shootingDate:  parseDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String),
            colorMode:     extractColorMode(from: props),
            pixelWidth:    props[kCGImagePropertyPixelWidth]           as? Int,
            pixelHeight:   props[kCGImagePropertyPixelHeight]          as? Int,
            fileSizeBytes: fileSize(at: url)
        )
    }

    // ファイルサイズをバイト単位で取得する。取得失敗（アクセス不可等）は非致命的なためnilを返す
    nonisolated private static func fileSize(at url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    // MARK: - Private

    // Sigma fp L の MakerNote から PictureMode（カラーモード）を取得する
    nonisolated private static func extractColorMode(from props: [CFString: Any]) -> String? {
        let makerNoteValue = props["{MakerNote}" as CFString]

        // Step 1: ImageIO が MakerNote を辞書として解釈できた場合はそのまま利用する
        if let makerNote = makerNoteValue as? [String: Any],
           let mode = makerNote["PictureMode"] as? String,
           mode != "Off" {
            return mode
        }

        // Step 2（未検証のフォールバック）:
        // Sigma の MakerNote は非公開のバイナリ形式であり、ImageIO では
        // [String: Any] へのキャストに失敗し常に Data のまま返ってくることが多いと考えられる。
        // Sigma は独自IFD内の各タグID（PictureModeに対応するタグ番号など）を公開しておらず、
        // オフセット構造を憶測でパースするのは危険なため本実装では行わない。
        // 代わりに、Sigma fp / fp L のカメラメニューで選択できる「カラーモード」名は
        // 公式マニュアルに載っている固定の文字列セットであり、MakerNoteバイナリ内に
        // ASCII文字列としてそのまま埋め込まれているケースがあるという前提のヒューリスティックで、
        // 既知のモード名がバイナリ中に含まれていないか走査する。
        // 実機のSigma fp L DNG/JPEGサンプルでは検証できていないため、
        // 一致しない場合・想定外の構造の場合は必ず nil を返し、誤ったカラーモード表示を避ける。
        // TODO: 実機サンプルが手に入り次第、この一覧と判定方法の妥当性を検証すること
        if let makerNoteData = makerNoteValue as? Data {
            let text = String(decoding: makerNoteData, as: UTF8.self)
            for mode in Self.knownSigmaColorModeNames where text.contains(mode) {
                return mode
            }
        }

        return nil
    }

    // Sigma fp / fp L のカメラメニューで選択可能な既知のカラーモード名（公式マニュアル記載の名称）。
    // MakerNoteバイナリの内部構造は非公開のため、この一覧はASCII文字列の単純一致判定にのみ使用する
    private static let knownSigmaColorModeNames: [String] = [
        "FOV Classic Blue",
        "FOV Classic Yellow",
        "Teal and Orange",
        "Powder Blue",
        "Warm Gold",
        "Sunset Red",
        "Forest Green",
        "Standard",
        "Vivid",
        "Neutral",
        "Portrait",
        "Landscape",
        "Cinema",
        "Monochrome"
    ]

    nonisolated private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return dateFormatter.date(from: string)
    }
}

// EXIF 読み取り結果（非永続・表示用）
struct EXIFInfo: Sendable {
    var cameraMake:   String?
    var cameraModel:  String?
    var lensModel:    String?
    var aperture:     Double?      // F値
    var shutterSpeed: Double?      // 秒
    var iso:          Int?
    var focalLength:  Double?      // mm
    var shootingDate: Date?
    var colorMode:    String?      // Sigma fp L 等のカラーモード名
    var pixelWidth:   Int?
    var pixelHeight:  Int?
    var fileSizeBytes: Int64?
}
