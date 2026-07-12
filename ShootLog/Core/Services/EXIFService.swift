import Foundation
import ImageIO

// ImageIO を使って EXIF 情報を非同期で読み取るサービス
actor EXIFService {
    static let shared = EXIFService()
    private init() {}

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    // 指定 URL の写真から EXIF を読み取る。バックグラウンドスレッドで呼ぶこと
    func readEXIF(from url: URL) throws -> EXIFInfo {
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
            colorMode:     extractColorMode(from: props)
        )
    }

    // MARK: - Private

    // Sigma fp L の MakerNote から PictureMode を取得する
    // Step 1: CGImageSourceCopyPropertiesAtIndex で直接取得を試みる
    private func extractColorMode(from props: [CFString: Any]) -> String? {
        // DNG MakerNote は辞書キー "{MakerNote}" で取得できる場合がある
        if let makerNote = props["{MakerNote}" as CFString] as? [String: Any],
           let mode = makerNote["PictureMode"] as? String,
           mode != "Off" {
            return mode
        }
        return nil
    }

    private func parseDate(_ string: String?) -> Date? {
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
}
