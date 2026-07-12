import SwiftUI

// 右カラムの EXIF パネル（156pt 固定幅）
struct EXIFPanelView: View {
    var photo: Photo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                EXIFRow(label: "ファイル名", value: photo?.fileURL.lastPathComponent)
                Divider()
                EXIFRow(label: "カメラ",    value: photo?.cameraModel)
                EXIFRow(label: "レンズ",    value: photo?.lensModel)
                Divider()
                EXIFRow(label: "絞り",      value: photo?.aperture.map { String(format: "f / %.1f", $0) },      isNumeric: true)
                EXIFRow(label: "SS",        value: shutterSpeedText,                                                  isNumeric: true)
                EXIFRow(label: "ISO",       value: photo?.iso.map { "\($0)" },                                       isNumeric: true)
                EXIFRow(label: "焦点距離",  value: photo?.focalLength.map { String(format: "%.0f mm", $0) },         isNumeric: true)
                Divider()
                // cameraModel がある = EXIF 読み込み済みのため撮影日時を表示する
                EXIFRow(label: "撮影日時",  value: photo?.cameraModel != nil
                    ? photo?.shootingDate.formatted(date: .abbreviated, time: .shortened)
                    : nil)

                // カラーモード（Sigma fp L 等）。"Off" / nil は非表示
                if let mode = photo?.colorMode, mode != "Off" {
                    EXIFColorModeBadge(mode: mode)
                }

                // お気に入り状態
                EXIFFavoriteRow(isFavorite: photo?.isFavorite ?? false)

                // メモ
                if let note = photo?.note, !note.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("メモ").font(.caption2).foregroundStyle(.secondary)
                        Text(note).font(.caption)
                    }
                }
            }
            .padding(Spacing.large)
        }
        .frame(width: 156)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            // 中央カラム（ビューア）との境界線。列全体をフラット化したため
            // 角丸グラスの代わりに細いボーダーで区切る（左カラムと対）
            Rectangle()
                .fill(Color.controlBorder)
                .frame(width: 0.5)
        }
    }

    private var shutterSpeedText: String? {
        guard let ss = photo?.shutterSpeed else { return nil }
        if ss >= 1 { return String(format: "%.1f s", ss) }
        let denom = Int((1.0 / ss).rounded())
        return "1/\(denom) s"
    }
}

// MARK: - Helper Views

private struct EXIFRow: View {
    let label: String
    let value: String?
    // 数値系の行（絞り・SS・ISO・焦点距離）は numericText トランジションを使う
    var isNumeric: Bool = false

    var body: some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
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
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(mode)
                .font(.caption)
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
                .font(.caption)
            Text(isFavorite ? "お気に入り" : "未登録")
                .font(.caption)
                .foregroundStyle(isFavorite ? .primary : .secondary)
        }
    }
}
