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
    var apertureText: String? { photo?.aperture.map { String(format: "f / %.1f", $0) } }
    var shutterSpeedText: String? { Self.shutterSpeedText(for: photo?.shutterSpeed) }
    var isoText: String? { photo?.iso.map { "\($0)" } }
    var focalLengthText: String? { photo?.focalLength.map { String(format: "%.0f mm", $0) } }

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

    // シャッタースピードを "1/xxx s" もしくは "x.x s" 表記に変換する
    private static func shutterSpeedText(for value: Double?) -> String? {
        guard let ss = value else { return nil }
        if ss >= 1 { return String(format: "%.1f s", ss) }
        let denom = Int((1.0 / ss).rounded())
        return "1/\(denom) s"
    }
}
