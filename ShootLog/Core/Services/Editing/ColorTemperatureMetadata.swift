import Foundation
import ImageIO

/// 非 RAW 画像の色温度メタデータ（EXIF / MakerNote）の解析。
enum ColorTemperatureMetadata {

    /// 非 RAW に保存されることがある色温度メタデータをベストエフォートで読む。
    static func read(from url: URL) -> Double? {
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
}
