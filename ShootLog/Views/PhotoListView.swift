import SwiftUI
import AppKit

// 左サイドバーの写真一覧（adaptiveグリッド。幅に応じて1↔2列に自動切替）
struct PhotoListView: View {
    let photos: [Photo]
    @Binding var selection: Photo?

    // minimum/maximum のみ指定し、閾値は意図的にハードコードしない（LazyVGridのadaptive挙動に一任）
    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 240), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(photos) { photo in
                    PhotoGridCell(
                        photo: photo,
                        isSelected: selection?.id == photo.id
                    ) {
                        selection = photo
                    }
                }
            }
            .padding(Spacing.xLarge) // 外周 > セル間隔(Spacing.medium)の階層をつくる
        }
    }
}

// MARK: - Grid Cell

private struct PhotoGridCell: View {
    let photo: Photo
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var vm = PhotoThumbnailViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnailView
                .frame(maxWidth: .infinity)
                .aspectRatio(3 / 2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                .background {
                    // 選択状態を面塗りでも識別できるようにする（ストロークのみだと暗い写真上で視認しづらいため）
                    if isSelected {
                        RoundedRectangle(cornerRadius: CornerRadius.small)
                            .fill(Color.accentColor.opacity(0.15))
                    }
                }
                .overlay {
                    // Listが自動提供していた選択ハイライトの代替
                    if isSelected {
                        RoundedRectangle(cornerRadius: CornerRadius.small)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }

            HStack(spacing: 4) {
                Text(photo.fileURL.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if photo.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true) // 状態はセル全体のaccessibilityLabelで伝える
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() } // Listの暗黙選択動作の代替
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAddTraits(.isButton)
        .task { await vm.load(photo: photo) }
    }

    private var accessibilityLabelText: String {
        photo.isFavorite
            ? String(localized: "a11y.photo.favorite \(photo.fileURL.lastPathComponent)")
            : photo.fileURL.lastPathComponent
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail = vm.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .overlay { ProgressView().scaleEffect(0.5) }
        }
    }
}
