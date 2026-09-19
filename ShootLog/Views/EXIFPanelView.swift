import SwiftUI

// 右の標準インスペクタに表示する EXIF パネル。
// 幅・背景材質・区切り線は `.inspector` 側（SidebarModeView）が担当する
struct EXIFPanelView: View {
    var photo: Photo?
    // 成功要因タグのトグル通知。書込自体はContentViewModel側のfunnelが担当する
    var onToggleTag: (SuccessTagCategory) -> Void = { _ in }

    var body: some View {
        let vm = EXIFPanelViewModel(photo: photo)

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                EXIFCard {
                    EXIFRow(label: "exif.label.fileName", value: vm.fileNameText)
                    EXIFRow(label: "exif.label.dimensions", value: vm.dimensionsText, isNumeric: true)
                    EXIFRow(label: "exif.label.fileSize", value: vm.fileSizeText, isNumeric: true)
                }
                EXIFCard {
                    EXIFRow(label: "exif.label.camera", value: vm.cameraModelText)
                    EXIFRow(label: "exif.label.lens", value: vm.lensModelText)
                }
                EXIFCard {
                    EXIFRow(label: "exif.label.aperture", value: vm.apertureText, isNumeric: true)
                    EXIFRow(label: "exif.label.shutterSpeed", value: vm.shutterSpeedText, isNumeric: true)
                    EXIFRow(label: "exif.label.iso", value: vm.isoText, isNumeric: true)
                    EXIFRow(label: "exif.label.focalLength", value: vm.focalLengthText, isNumeric: true)
                }
                EXIFCard {
                    EXIFRow(label: "exif.label.shootingDate", value: vm.shootingDateText)

                    // カラーモード（Sigma fp L 等）。"Off" / nil は非表示
                    if let mode = vm.colorModeText {
                        EXIFColorModeBadge(mode: mode)
                    }
                }

                // AI分類（未分類時は非表示）
                if !vm.aiCategories.isEmpty {
                    EXIFCard {
                        EXIFAICategoryBadges(categories: vm.aiCategories)
                    }
                }

                // AI画質診断（未診断・指摘0件は非表示。判定と指摘生成は
                // EXIFPanelViewModel.qualityDiagnosisContent に集約）
                if let content = vm.qualityDiagnosisContent {
                    EXIFCard {
                        EXIFQualityDiagnosisCard(
                            overallScore: content.diagnosis.aestheticsScore,
                            insights: content.insights
                        )
                    }
                }

                // お気に入り状態
                EXIFCard {
                    EXIFFavoriteRow(isFavorite: vm.isFavorite)
                }

                // メモ
                if let note = vm.noteText {
                    EXIFCard {
                        Text("exif.label.note").font(.caption).foregroundStyle(.secondary)
                        Text(note).font(.subheadline)
                    }
                }

                // 成功要因タグ（写真未選択時は非表示）
                if vm.photo != nil {
                    EXIFCard {
                        Text("exif.label.successTags").font(.caption).foregroundStyle(.secondary)
                        EXIFSuccessTagPicker(
                            selectedTags: vm.successTags,
                            onToggle: onToggleTag
                        )
                    }
                }
            }
            .padding(Spacing.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Helper Views

// EXIF情報グループを角丸カードとして視覚的に区切るラッパー
// （左サイドバーのサムネイルカードと視覚言語を揃えるため）
private struct EXIFCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.medium)
        // インスペクタ自体が Material 背景を持つため、カードにも Material を重ねると
        // ライトモードで境界が消える。コンテンツ層には塗りで階層を付ける
        // （AnalysisView のセクションカードと同じ視覚言語）
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
    }
}

private struct EXIFRow: View {
    let label: LocalizedStringKey
    let value: String?
    // 数値系の行（絞り・SS・ISO・焦点距離）は numericText トランジションを使う
    var isNumeric: Bool = false

    var body: some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .contentTransition(isNumeric ? .numericText() : .opacity)
                    .animation(.easeInOut(duration: 0.2), value: value)
            }
        }
    }
}

private struct EXIFColorModeBadge: View {
    let mode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("exif.label.colorMode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(mode)
                .font(.subheadline)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15))
                .foregroundStyle(.tint)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

private struct EXIFAICategoryBadges: View {
    let categories: [AISubjectCategory]
    private let columns = [GridItem(.adaptive(minimum: 70), spacing: Spacing.small)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("exif.label.aiCategory")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.small) {
                ForEach(categories, id: \.self) { category in
                    Text(category.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15))
                        .foregroundStyle(.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        // .combine が見出し + 各バッジのTextを結合して読み上げる（"AI分類, 人物, 動物"）。
        // 固定accessibilityLabelを付けるとこの結合結果が上書きされ、カテゴリ名が読まれなくなるため付けない
        .accessibilityElement(children: .combine)
    }
}

// AI画質診断結果（統合スコア + 良い点/改善ポイントの箇条書き）
private struct EXIFQualityDiagnosisCard: View {
    let overallScore: Double?
    let insights: [PhotoQualityInsight]

    // aiAestheticsOverallScore は 0...1 で永続化されているため、分かりやすい 0-100 表現に変換する
    private var scorePercent: Int? {
        overallScore.map { Int(($0 * 100).rounded()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text("exif.label.qualityDiagnosis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let scorePercent {
                    // 見出しと結合して読み上げられるため、裸の数値のままだと意味が伝わらない。
                    // 子要素側にラベルを付けることで .combine の結合結果に単位付きの文言が載る
                    Text(String(scorePercent))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("a11y.exif.qualityDiagnosis.score \(scorePercent)")
                }
            }
            ForEach(insights) { insight in
                Label {
                    Text(insight.messageKey)
                        .font(.caption)
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
        .accessibilityElement(children: .combine)
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
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xSmall)
                        .padding(.horizontal, Spacing.small)
                        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
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
    }
}
