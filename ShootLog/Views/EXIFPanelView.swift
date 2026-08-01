import SwiftUI

// 右の標準インスペクタに表示する EXIF パネル。
// 幅・背景材質・区切り線は `.inspector` 側（SidebarModeView）が担当する
struct EXIFPanelView: View {
    var photo: Photo?
    @State private var vm = EXIFPanelViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                EXIFCard {
                    EXIFRow(label: "ファイル名", value: vm.fileNameText)
                }
                EXIFCard {
                    EXIFRow(label: "カメラ",    value: vm.cameraModelText)
                    EXIFRow(label: "レンズ",    value: vm.lensModelText)
                }
                EXIFCard {
                    EXIFRow(label: "絞り",      value: vm.apertureText,     isNumeric: true)
                    EXIFRow(label: "SS",        value: vm.shutterSpeedText, isNumeric: true)
                    EXIFRow(label: "ISO",       value: vm.isoText,          isNumeric: true)
                    EXIFRow(label: "焦点距離",  value: vm.focalLengthText,  isNumeric: true)
                }
                EXIFCard {
                    EXIFRow(label: "撮影日時",  value: vm.shootingDateText)

                    // カラーモード（Sigma fp L 等）。"Off" / nil は非表示
                    if let mode = vm.colorModeText {
                        EXIFColorModeBadge(mode: mode)
                    }
                }

                // お気に入り状態
                EXIFCard {
                    EXIFFavoriteRow(isFavorite: vm.isFavorite)
                }

                // メモ
                if let note = vm.noteText {
                    EXIFCard {
                        Text("メモ").font(.caption).foregroundStyle(.secondary)
                        Text(note).font(.subheadline)
                    }
                }
            }
            .padding(Spacing.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: photo?.id, initial: true) {
            vm.photo = photo
        }
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
