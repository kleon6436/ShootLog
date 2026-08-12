import Foundation

// EXIFPanelView（右インスペクタのEXIF表示）のViewModel
// photoを保持し、各表示用プロパティはcomputed propertyとして都度算出する。
// こうすることでView body評価中にphotoのプロパティが読まれ、SwiftUIの観測が
// 再登録されるため、EXIF非同期ロード完了・お気に入りトグル・メモ編集などの
// 事後変更が自動的にパネルへ反映される。
@Observable
@MainActor
final class EXIFPanelViewModel {
    var photo: Photo?

    var fileNameText: String? { photo?.fileURL.lastPathComponent }
    var cameraModelText: String? { photo?.cameraModel }
    var lensModelText: String? { photo?.lensModel }
    var apertureText: String? { photo?.aperture.map { "f / " + Self.decimalText($0, fractionLength: 1) } }
    var shutterSpeedText: String? { Self.shutterSpeedText(for: photo?.shutterSpeed) }
    var isoText: String? { photo?.iso.map { "\($0)" } }
    var focalLengthText: String? { photo?.focalLength.map { Self.decimalText($0, fractionLength: 0) + " mm" } }

    // cameraModel がある = EXIF 読み込み済みのため撮影日時を表示する
    var shootingDateText: String? {
        photo?.cameraModel != nil
            ? photo?.shootingDate.formatted(date: .abbreviated, time: .shortened)
            : nil
    }

    // カラーモード（Sigma fp L 等）。"Off" / nil のときは表示しないためnilを返す
    var colorModeText: String? {
        guard let mode = photo?.colorMode, mode != "Off" else { return nil }
        return mode
    }

    var isFavorite: Bool { photo?.isFavorite ?? false }

    // 成功要因タグの唯一の読取経路。View側は自身のphotoではなくこちらを参照する
    var successTags: [SuccessTagCategory] { photo?.successTags ?? [] }

    var noteText: String? {
        guard let note = photo?.note, !note.isEmpty else { return nil }
        return note
    }

    // 小数点記号をロケールに追随させる。桁区切りは撮影値の表記として不自然なため付けない
    private static func decimalText(_ value: Double, fractionLength: Int) -> String {
        value.formatted(.number.precision(.fractionLength(fractionLength)).grouping(.never))
    }

    // シャッタースピードを "1/xxx s" もしくは "x.x s" 表記に変換する
    private static func shutterSpeedText(for value: Double?) -> String? {
        guard let ss = value else { return nil }
        if ss >= 1 { return decimalText(ss, fractionLength: 1) + " s" }
        let denom = Int((1.0 / ss).rounded())
        return "1/\(denom) s"
    }
}
