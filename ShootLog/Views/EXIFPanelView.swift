import SwiftUI

// 右の標準インスペクタに表示する情報パネル。
// 設定画面と同じ `Form(.grouped)` + `Section` + `LabeledContent` に統一し、
// 「セクション見出し → ラベル左・値右の行」という 1 種類の並びだけで構成する。
// 幅・背景材質・区切り線は `.inspector` 側（SidebarModeView）が担当する
struct EXIFPanelView: View {
    var photo: Photo?
    // 成功要因タグのトグル通知。書込自体はContentViewModel側のfunnelが担当する
    var onToggleTag: (SuccessTagCategory) -> Void = { _ in }

    var body: some View {
        let vm = EXIFPanelViewModel(photo: photo)

        if vm.photo == nil {
            ContentUnavailableView("exif.empty.noSelection", systemImage: "info.circle")
        } else {
            Form {
                fileSection(vm)
                cameraSection(vm)
                exposureSection(vm)
                captureSection(vm)
                aiSubjectSection(vm)
                qualityDiagnosisSection(vm)
                ratingSection(vm)
                noteSection(vm)
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - セクション

    @ViewBuilder
    private func fileSection(_ vm: EXIFPanelViewModel) -> some View {
        Section("exif.section.file") {
            if let fileName = vm.fileNameText {
                LabeledContent("exif.label.fileName") {
                    EXIFValueText(fileName, truncation: .middle)
                }
            }
            if let dimensions = vm.dimensionsText {
                LabeledContent("exif.label.dimensions") { EXIFValueText(dimensions, numeric: true) }
            }
            if let fileSize = vm.fileSizeText {
                LabeledContent("exif.label.fileSize") { EXIFValueText(fileSize, numeric: true) }
            }
            if let format = Self.formatText(for: vm.photo) {
                LabeledContent("exif.label.format") { EXIFValueText(format) }
            }
        }
    }

    @ViewBuilder
    private func cameraSection(_ vm: EXIFPanelViewModel) -> some View {
        if vm.cameraModelText != nil || vm.lensModelText != nil {
            Section("exif.section.camera") {
                if let camera = vm.cameraModelText {
                    LabeledContent("exif.label.camera") { EXIFValueText(camera) }
                }
                if let lens = vm.lensModelText {
                    LabeledContent("exif.label.lens") { EXIFValueText(lens) }
                }
            }
        }
    }

    // 露出 4 項目は未取得でも "—" で行を残し、行数が写真ごとに変わらないようにする
    @ViewBuilder
    private func exposureSection(_ vm: EXIFPanelViewModel) -> some View {
        Section("exif.section.exposure") {
            LabeledContent("exif.label.aperture") { EXIFValueText(vm.apertureText ?? "—", numeric: true) }
            LabeledContent("exif.label.shutterSpeed") { EXIFValueText(vm.shutterSpeedText ?? "—", numeric: true) }
            LabeledContent("exif.label.iso") { EXIFValueText(vm.isoText ?? "—", numeric: true) }
            LabeledContent("exif.label.focalLength") { EXIFValueText(vm.focalLengthText ?? "—", numeric: true) }
        }
    }

    @ViewBuilder
    private func captureSection(_ vm: EXIFPanelViewModel) -> some View {
        let whiteBalance = whiteBalanceText(vm)
        if vm.shootingDateText != nil || whiteBalance != nil || vm.colorModeText != nil {
            Section("exif.section.capture") {
                if let shootingDate = vm.shootingDateText {
                    LabeledContent("exif.label.shootingDate") { EXIFValueText(shootingDate, numeric: true) }
                }
                if let whiteBalance {
                    LabeledContent("exif.label.whiteBalance") { EXIFValueText(whiteBalance, numeric: true) }
                }
                if let colorMode = vm.colorModeText {
                    LabeledContent("exif.label.colorMode") {
                        Text(colorMode)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15))
                            .foregroundStyle(.tint)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func aiSubjectSection(_ vm: EXIFPanelViewModel) -> some View {
        if !vm.aiCategories.isEmpty {
            Section {
                EXIFChipFlow(categories: vm.aiCategories)
                    // .combine が各チップの Text を結合して読み上げる（"人物, 動物"）。
                    // 固定 accessibilityLabel を付けるとこの結合結果が上書きされ、カテゴリ名が読まれなくなるため付けない
                    .accessibilityElement(children: .combine)
            } header: {
                Text("exif.label.aiSubject")
            } footer: {
                Text("exif.label.aiOnDevice")
            }
        }
    }

    @ViewBuilder
    private func qualityDiagnosisSection(_ vm: EXIFPanelViewModel) -> some View {
        if let content = vm.qualityDiagnosisContent {
            Section {
                LabeledContent("exif.label.qualityScore") {
                    EXIFScoreRing(overallScore: content.diagnosis.aestheticsScore)
                }
                ForEach(content.insights) { insight in
                    Label {
                        Text(insight.messageKey)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(
                            systemName: insight.kind == .positive
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        // good/bad 状態を示す意味的ステータス色。SwiftUI のセマンティック動的カラーで
                        // light/dark 自動対応しており、生の RGB リテラル直書きではないため CLAUDE.md 色規約の対象外
                        .foregroundStyle(insight.kind == .positive ? .green : .orange)
                    }
                }
            } header: {
                Text("exif.label.qualityDiagnosis")
            } footer: {
                Text("exif.label.qualityDiagnosisAxes")
            }
        }
    }

    @ViewBuilder
    private func ratingSection(_ vm: EXIFPanelViewModel) -> some View {
        Section("exif.section.rating") {
            LabeledContent("exif.label.favorite") {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: vm.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(vm.isFavorite ? .yellow : .secondary)
                    Text(vm.isFavorite ? "exif.favorite.registered" : "exif.favorite.unregistered")
                        .foregroundStyle(vm.isFavorite ? .primary : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("exif.label.successTags")
                EXIFSuccessTagPicker(selectedTags: vm.successTags, onToggle: onToggleTag)
            }
        }
    }

    @ViewBuilder
    private func noteSection(_ vm: EXIFPanelViewModel) -> some View {
        if let note = vm.noteText {
            Section("exif.label.note") {
                Text(note)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 派生値

    // 撮影時ホワイトバランス（Kelvin）は develop.whiteBalance.* の既存ステータス語
    // （撮影時/推定）を埋め込んだ 1 文にまとめる。語順の言語差に対応するため
    // 位置指定プレースホルダー経由（exif.value.whiteBalance）で組み立てる
    private func whiteBalanceText(_ vm: EXIFPanelViewModel) -> String? {
        guard let kelvin = vm.photo?.asShotTemperatureKelvin else { return nil }
        let isEstimated = vm.photo?.asShotWhiteBalanceIsEstimated ?? false
        let statusWord = isEstimated
            ? String(localized: "develop.whiteBalance.estimated")
            : String(localized: "develop.whiteBalance.mode.asShot")
        return String(localized: "exif.value.whiteBalance \(statusWord) \(Int(kelvin.rounded()))")
    }

    // ファイル拡張子からおおまかなフォーマット表示名を導く。ファイル拡張子自体と
    // 同様に非ローカライズ対象（CLAUDE.md「ローカライズしないもの」）。
    // NSString/URL に頼らず Swift 標準ライブラリのみで拡張子を取り出す
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

// LabeledContent の値側テキスト。右寄せ・2 行まで折り返し・選択可を全行で揃える
private struct EXIFValueText: View {
    let text: String
    var numeric = false
    var truncation: Text.TruncationMode = .tail

    init(_ text: String, numeric: Bool = false, truncation: Text.TruncationMode = .tail) {
        self.text = text
        self.numeric = numeric
        self.truncation = truncation
    }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .lineLimit(truncation == .middle ? 1 : 2)
            .truncationMode(truncation)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .contentTransition(numeric ? .numericText() : .opacity)
            .animation(.easeInOut(duration: 0.2), value: text)
    }
}

// 被写体カテゴリなど表示専用のチップ列
private struct EXIFChipFlow: View {
    let categories: [AISubjectCategory]
    private let columns = [GridItem(.adaptive(minimum: 70), spacing: Spacing.small)]

    var body: some View {
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
}

// AI 画質診断の統合スコア（0-100）。小さなリングと数値を 1 行の値として出す
private struct EXIFScoreRing: View {
    let overallScore: Double?

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
        HStack(spacing: Spacing.small) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                if let scorePercent {
                    Circle()
                        .trim(from: 0, to: CGFloat(scorePercent) / 100)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 18, height: 18)
            Text(scorePercent.map(String.init) ?? "—")
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("exif.label.qualityScore")
        .accessibilityValue(scorePercent.map { Text("a11y.exif.qualityDiagnosis.score \($0)") } ?? Text(verbatim: "—"))
    }
}

// 成功要因タグの複数選択トグル。パネル幅が可変のため折り返しグリッドで配置する
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
