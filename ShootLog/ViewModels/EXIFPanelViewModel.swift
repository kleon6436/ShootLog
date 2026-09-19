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

    init(photo: Photo? = nil) {
        self.photo = photo
    }

    var fileNameText: String? { photo?.displayFileName }
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

    var dimensionsText: String? {
        guard let w = photo?.pixelWidth, let h = photo?.pixelHeight else { return nil }
        return "\(w) x \(h)"
    }

    var fileSizeText: String? {
        guard let bytes = photo?.fileSizeBytes else { return nil }
        return Self.byteCountFormatter.string(fromByteCount: bytes)
    }

    var isFavorite: Bool { photo?.isFavorite ?? false }

    // 成功要因タグの唯一の読取経路。View側は自身のphotoではなくこちらを参照する
    var successTags: [SuccessTagCategory] { photo?.successTags ?? [] }

    var aiCategories: [AISubjectCategory] {
        (photo?.aiCategoryRawValues ?? []).compactMap { AISubjectCategory(rawValue: $0) }
    }

    // 画質診断カードの表示内容。表示可否の判定と指摘の生成をまとめ、View側での再計算を避ける
    struct QualityDiagnosisContent {
        let diagnosis: PhotoQualityDiagnosis
        let insights: [PhotoQualityInsight]
    }

    // 未診断、またはスコア・指摘が1件も無い（＝空カードになる）場合にnilを返し、
    // EXIFQualityDiagnosisCardを非表示にする。
    // isUtilityによる抑制は「統合スコアの良い点」だけに限定し（PhotoQualityInsightBuilder側）、
    // カード全体の表示可否には使わない。露出・シャープネス等は書類的な写真でも有効な指摘のため
    var qualityDiagnosisContent: QualityDiagnosisContent? {
        guard let photo, photo.aiDiagnosisFetchedAt != nil else { return nil }
        let diagnosis = PhotoQualityDiagnosis(
            aestheticsScore: photo.aiAestheticsOverallScore,
            isUtility: photo.aiAestheticsIsUtility ?? false,
            faceQualityScore: photo.aiFaceQualityScore,
            exposureBias: photo.aiExposureBias,
            sharpnessScore: photo.aiSharpnessScore,
            compositionOffsetScore: photo.aiCompositionOffsetScore
        )
        let insights = PhotoQualityInsightBuilder.buildInsights(from: diagnosis)
        guard diagnosis.aestheticsScore != nil || !insights.isEmpty else { return nil }
        return QualityDiagnosisContent(diagnosis: diagnosis, insights: insights)
    }

    var noteText: String? {
        guard let note = photo?.note, !note.isEmpty else { return nil }
        return note
    }

    // ファイルサイズ表示用フォーマッタ。ロケールに応じた単位・桁区切りをシステムに委ねる
    private static let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

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
