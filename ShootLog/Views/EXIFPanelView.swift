import SwiftUI

// 右の標準インスペクタに表示する EXIF パネル。
// 幅・背景材質・区切り線は `.inspector` 側（SidebarModeView）が担当する
struct EXIFPanelView: View {
    var photo: Photo?
    // 成功要因タグのトグル通知。書込自体はContentViewModel側のfunnelが担当する
    var onToggleTag: (SuccessTagCategory) -> Void = { _ in }

    var body: some View {
        let vm = EXIFPanelViewModel(photo: photo)

        // 撮影時ホワイトバランス（Kelvin）は develop.whiteBalance.* の既存ステータス語
        // （撮影時/推定）を埋め込んだ1文にまとめる。語順の言語差に対応するため
        // 位置指定プレースホルダー経由（exif.value.whiteBalance）で組み立てる
        let whiteBalanceText: String? = {
            guard let kelvin = vm.photo?.asShotTemperatureKelvin else { return nil }
            let isEstimated = vm.photo?.asShotWhiteBalanceIsEstimated ?? false
            let statusWord = isEstimated
                ? String(localized: "develop.whiteBalance.estimated")
                : String(localized: "develop.whiteBalance.mode.asShot")
            return String(localized: "exif.value.whiteBalance \(statusWord) \(Int(kelvin.rounded()))")
        }()

        var cameraRows: [(label: LocalizedStringKey, value: EXIFRowValue)] {
            var rows: [(LocalizedStringKey, EXIFRowValue)] = []
            if let camera = vm.cameraModelText { rows.append(("exif.label.camera", .text(camera))) }
            if let lens = vm.lensModelText { rows.append(("exif.label.lens", .text(lens))) }
            return rows
        }

        var dateRows: [(label: LocalizedStringKey, value: EXIFRowValue)] {
            var rows: [(LocalizedStringKey, EXIFRowValue)] = []
            if let shootingDate = vm.shootingDateText {
                rows.append(("exif.label.shootingDate", .text(shootingDate)))
            }
            if let whiteBalanceText {
                rows.append(("exif.label.whiteBalance", .text(whiteBalanceText)))
            }
            if let colorMode = vm.colorModeText {
                rows.append(("exif.label.colorMode", .badge(colorMode)))
            }
            return rows
        }

        ScrollView {
            VStack(spacing: Spacing.xLarge) {
                EXIFFileCard(
                    fileName: vm.fileNameText,
                    dimensions: vm.dimensionsText,
                    fileSize: vm.fileSizeText,
                    format: Self.formatText(for: vm.photo)
                )

                EXIFGroupedRowsCard(rows: cameraRows)

                EXIFExposureGrid(
                    aperture: vm.apertureText,
                    shutterSpeed: vm.shutterSpeedText,
                    iso: vm.isoText,
                    focalLength: vm.focalLengthText
                )

                EXIFGroupedRowsCard(rows: dateRows)

                // AI分類（未分類時は非表示）
                EXIFAISubjectCard(categories: vm.aiCategories)

                // AI画質診断（未診断・指摘0件は非表示。判定と指摘生成は
                // EXIFPanelViewModel.qualityDiagnosisContent に集約）
                if let content = vm.qualityDiagnosisContent {
                    EXIFQualityDiagnosisCard(
                        overallScore: content.diagnosis.aestheticsScore,
                        insights: content.insights
                    )
                }

                // お気に入り状態
                EXIFFavoriteRow(isFavorite: vm.isFavorite)
                    .contentCard()

                // メモ
                if let note = vm.noteText {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text("exif.label.note")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.body)
                    }
                    .contentCard()
                }

                // 成功要因タグ（写真未選択時は非表示）
                if vm.photo != nil {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text("exif.label.successTags")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        EXIFSuccessTagPicker(
                            selectedTags: vm.successTags,
                            onToggle: onToggleTag
                        )
                    }
                    .contentCard()
                }
            }
            .padding(.horizontal, Spacing.xLarge)
            .padding(.vertical, Spacing.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ファイル拡張子からおおまかなフォーマット表示名を導く。ファイル拡張子自体と
    // 同様に非ローカライズ対象（CLAUDE.md「ローカライズしないもの」）。
    // NSString/URLに頼らずSwift標準ライブラリのみで拡張子を取り出す
    private static func formatText(for photo: Photo?) -> String? {
        guard let name = photo?.displayFileName else { return nil }
        let components = name.split(separator: ".")
        guard components.count > 1, let last = components.last else { return nil }
        let ext = last.lowercased()
        let rawExtensions: Set<String> = ["nef", "dng", "arw", "cr3", "raf"]
        if rawExtensions.contains(ext) { return "RAW" }
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "heic": return "HEIC"
        case "tiff": return "TIFF"
        case "png": return "PNG"
        default: return ext.uppercased()
        }
    }
}

// MARK: - Helper Views

// ファイルカード: ファイル名 + 寸法・サイズ・フォーマットのキャプション行
private struct EXIFFileCard: View {
    let fileName: String?
    let dimensions: String?
    let fileSize: String?
    let format: String?

    private var hasCaption: Bool { dimensions != nil || fileSize != nil || format != nil }

    var body: some View {
        if let fileName {
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if hasCaption {
                    HStack(spacing: Spacing.xLarge) {
                        if let dimensions {
                            Text(dimensions)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.2), value: dimensions)
                        }
                        if let fileSize {
                            Text(fileSize)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.2), value: fileSize)
                        }
                        if let format {
                            Text(format)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
            .contentCard()
        }
    }
}

// カメラ・日時カード共通の「Form風」行の値。テキストか、カラーモードのような
// 強調バッジかを切り替える
private enum EXIFRowValue {
    case text(String)
    case badge(String)
}

private struct EXIFRowValueView: View {
    let value: EXIFRowValue

    var body: some View {
        switch value {
        case .text(let text):
            Text(text)
                .font(.body)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: text)
        case .badge(let text):
            Text(text)
                .font(.body)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15))
                .foregroundStyle(.tint)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
        }
    }
}

// カメラ・レンズ、撮影日時・ホワイトバランス・カラーモードで使う
// グループ化Form風のカード（区切り線入り、行高30）。行が0件のときはカード自体を隠す
private struct EXIFGroupedRowsCard: View {
    let rows: [(label: LocalizedStringKey, value: EXIFRowValue)]

    var body: some View {
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Spacer(minLength: Spacing.xLarge)
                        EXIFRowValueView(value: row.value)
                    }
                    .frame(minHeight: 30)
                    .padding(.vertical, Spacing.xSmall)
                    .padding(.horizontal, Spacing.xLarge)

                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .contentCard(padding: 0)
        }
    }
}

// 絞り・SS・ISO・焦点距離を4列タイルで並べる
private struct EXIFExposureGrid: View {
    let aperture: String?
    let shutterSpeed: String?
    let iso: String?
    let focalLength: String?

    // 幅が足りないときは 2 列に折り返す（インスペクタ最小幅でも値を切り詰めない）
    private let columns = [GridItem(.adaptive(minimum: 62, maximum: 120), spacing: Spacing.small)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.small) {
            EXIFExposureTile(value: aperture, label: "exif.label.aperture")
            EXIFExposureTile(value: shutterSpeed, label: "exif.label.shutterSpeed")
            EXIFExposureTile(value: iso, label: "exif.label.iso")
            EXIFExposureTile(value: focalLength, label: "exif.label.focalLength")
        }
    }
}

private struct EXIFExposureTile: View {
    let value: String?
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 4) {
            Text(value ?? "—")
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: value)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.medium)
        .frame(maxWidth: .infinity)
        .contentCard(padding: 0)
    }
}

private struct EXIFAISubjectCard: View {
    let categories: [AISubjectCategory]
    private let columns = [GridItem(.adaptive(minimum: 70), spacing: Spacing.small)]

    var body: some View {
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(alignment: .firstTextBaseline) {
                    Text("exif.label.aiSubject")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("exif.label.aiOnDevice")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.small) {
                    ForEach(categories, id: \.self) { category in
                        Text(category.displayName)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(.tint.opacity(0.18))
                            .foregroundStyle(.tint)
                            .clipShape(Capsule())
                    }
                }
            }
            .contentCard()
            // .combine が見出し + 各バッジのTextを結合して読み上げる（"被写体, 人物, 動物"）。
            // 固定accessibilityLabelを付けるとこの結合結果が上書きされ、カテゴリ名が読まれなくなるため付けない
            .accessibilityElement(children: .combine)
        }
    }
}

// AI画質診断結果（統合スコアのリング + 良い点/改善ポイントの箇条書き）
private struct EXIFQualityDiagnosisCard: View {
    let overallScore: Double?
    let insights: [PhotoQualityInsight]

    // aiAestheticsOverallScore は 0...1 で永続化されているため、分かりやすい 0-100 表現に変換する
    private var scorePercent: Int? {
        overallScore.map { Int(($0 * 100).rounded()) }
    }

    private var ringColor: Color {
        guard let scorePercent else { return .secondary }
        if scorePercent >= 70 { return .green }
        if scorePercent >= 40 { return .orange }
        return .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.medium) {
                scoreRing
                VStack(alignment: .leading, spacing: 2) {
                    // 見出しはリングの accessibilityLabel と同文のため VoiceOver では読まない（二重読み上げ防止）
                    Text("exif.label.qualityDiagnosis")
                        .font(.headline)
                        .accessibilityHidden(true)
                    Text("exif.label.qualityDiagnosisAxes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(insights) { insight in
                Label {
                    Text(insight.messageKey)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(
                        systemName: insight.kind == .positive
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    // good/bad状態を示す意味的ステータス色。SwiftUIのセマンティック動的カラーで
                    // light/dark自動対応しており、生のRGBリテラル直書きではないためCLAUDE.md色規約の対象外
                    .foregroundStyle(insight.kind == .positive ? .green : .orange)
                }
            }
        }
        .contentCard()
        // カード全体を 1 要素として読み上げる（変更前と同じ挙動）
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var scoreRing: some View {
        let ring = ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 4)
            if let scorePercent {
                Circle()
                    .trim(from: 0, to: CGFloat(scorePercent) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(String(scorePercent))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("exif.label.qualityDiagnosis")

        if let scorePercent {
            ring.accessibilityValue("a11y.exif.qualityDiagnosis.score \(scorePercent)")
        } else {
            ring
        }
    }
}

// 成功要因タグの複数選択トグル。パネル幅が可変（180〜300pt）のため折り返しグリッドで配置する
private struct EXIFSuccessTagPicker: View {
    let selectedTags: [SuccessTagCategory]
    let onToggle: (SuccessTagCategory) -> Void

    private let columns = [GridItem(.adaptive(minimum: 60), spacing: Spacing.small)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.small) {
            ForEach(SuccessTagCategory.allCases, id: \.self) { category in
                let isSelected = selectedTags.contains(category)
                Button {
                    onToggle(category)
                } label: {
                    Text(category.displayName)
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xSmall)
                        .padding(.horizontal, Spacing.small)
                        .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.secondary))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("a11y.exif.successTag \(category.displayName)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

private struct EXIFFavoriteRow: View {
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
                .font(.subheadline)
            Text(isFavorite ? "exif.favorite.registered" : "exif.favorite.unregistered")
                .font(.subheadline)
                .foregroundStyle(isFavorite ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
