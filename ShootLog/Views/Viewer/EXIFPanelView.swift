import SwiftUI

// 右の標準インスペクタに表示する EXIF パネル。
// 幅・背景材質・区切り線は `.inspector` 側（SidebarModeView）が担当する
struct EXIFPanelView: View {
    var photo: Photo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                EXIFCard {
                    EXIFRow(label: "ファイル名", value: photo?.fileURL.lastPathComponent)
                }
                EXIFCard {
                    EXIFRow(label: "カメラ",    value: photo?.cameraModel)
                    EXIFRow(label: "レンズ",    value: photo?.lensModel)
                }
                EXIFCard {
                    EXIFRow(label: "絞り",      value: photo?.aperture.map { String(format: "f / %.1f", $0) },      isNumeric: true)
                    EXIFRow(label: "SS",        value: shutterSpeedText,                                                  isNumeric: true)
                    EXIFRow(label: "ISO",       value: photo?.iso.map { "\($0)" },                                       isNumeric: true)
                    EXIFRow(label: "焦点距離",  value: photo?.focalLength.map { String(format: "%.0f mm", $0) },         isNumeric: true)
                }
                EXIFCard {
                    // cameraModel がある = EXIF 読み込み済みのため撮影日時を表示する
                    EXIFRow(label: "撮影日時",  value: photo?.cameraModel != nil
                        ? photo?.shootingDate.formatted(date: .abbreviated, time: .shortened)
                        : nil)

                    // カラーモード（Sigma fp L 等）。"Off" / nil は非表示
                    if let mode = photo?.colorMode, mode != "Off" {
                        EXIFColorModeBadge(mode: mode)
                    }
                }

                // お気に入り状態
                EXIFCard {
                    EXIFFavoriteRow(isFavorite: photo?.isFavorite ?? false)
                }

                // メモ
                if let note = photo?.note, !note.isEmpty {
                    EXIFCard {
                        Text("メモ").font(.caption).foregroundStyle(.secondary)
                        Text(note).font(.subheadline)
                    }
                }
            }
            .padding(Spacing.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shutterSpeedText: String? {
        guard let ss = photo?.shutterSpeed else { return nil }
        if ss >= 1 { return String(format: "%.1f s", ss) }
        let denom = Int((1.0 / ss).rounded())
        return "1/\(denom) s"
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
        .glassOrMaterial(cornerRadius: CornerRadius.medium)
    }
}

private struct EXIFRow: View {
    let label: String
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
            Text("カラーモード")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(mode)
                .font(.subheadline)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 4))
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
            Text(isFavorite ? "お気に入り" : "未登録")
                .font(.subheadline)
                .foregroundStyle(isFavorite ? .primary : .secondary)
        }
    }
}
