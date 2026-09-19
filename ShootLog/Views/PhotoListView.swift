import SwiftUI
import AppKit

// セルの右クリックメニューが呼ぶアクション束。PhotoListView を presentational なまま保つため
// （ViewModel を直接注入しない）、組み立ては呼び出し側（SidebarModeView）の責務とする。
// 各アクションは対象写真を選択状態にしてから既存の選択依存APIを呼ぶ実装を想定する
struct PhotoContextMenuActions {
    // 「外部アプリで開く」に並べるアダプター一覧。Launch Services への照会が
    // セル数×アダプタ数だけ走らないよう、呼び出し側で1度だけ評価して渡す
    let externalApps: [any ExternalAppProtocol]
    let openInExternalApp: (Photo, any ExternalAppProtocol) -> Void
    let toggleFavorite: (Photo) -> Void
    let toggleSuccessTag: (Photo, SuccessTagCategory) -> Void
    let showDevelopPanel: (Photo) -> Void
    let rotate: (Photo) -> Void
    let copyFileName: (Photo) -> Void
    let copyFilePath: (Photo) -> Void
}

// 左サイドバーの写真一覧（adaptiveグリッド。幅に応じて1↔2列に自動切替）
struct PhotoListView: View {
    let photos: [Photo]
    @Binding var selection: Photo?
    let contextMenuActions: PhotoContextMenuActions

    // minimum/maximum のみ指定し、閾値は意図的にハードコードしない（LazyVGridのadaptive挙動に一任）
    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 240), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(photos) { photo in
                    PhotoGridCell(
                        photo: photo,
                        isSelected: selection?.id == photo.id,
                        actions: contextMenuActions
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
    let actions: PhotoContextMenuActions
    let onSelect: () -> Void
    @State private var vm = PhotoThumbnailViewModel()

    private var availability: PhotoActionAvailability {
        PhotoActionAvailability(photo: photo, hasExternalApps: !actions.externalApps.isEmpty)
    }

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
                Text(photo.displayFileName)
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
        // メニュー項目自体は対象写真を選択してから実行するため、ここでは選択を先取りしない
        // （メニューを開いただけで選択が動くのを避ける）
        .contextMenu { contextMenuItems }
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAddTraits(.isButton)
        .task { await vm.load(photo: photo) }
    }

    // 型チェックの負荷を避けるため、メニュー本体は body から切り出す
    @ViewBuilder
    private var contextMenuItems: some View {
        Menu("contextMenu.openWith") {
            ForEach(actions.externalApps, id: \.id) { adapter in
                Button { actions.openInExternalApp(photo, adapter) } label: {
                    Label(adapter.displayName, systemImage: adapter.symbolName)
                }
            }
        }
        .disabled(!availability.canOpenExternally)

        Button(photo.isFavorite ? "contextMenu.favorite.remove" : "contextMenu.favorite.add") {
            actions.toggleFavorite(photo)
        }

        Menu("contextMenu.successTag") {
            ForEach(SuccessTagCategory.allCases, id: \.self) { tag in
                // チェックマークの描画はOS標準のメニュー用Toggleに任せる（AICategoryFilterMenuと同じ方式）
                Toggle(isOn: successTagBinding(for: tag)) {
                    Text(tag.displayName)
                }
            }
        }

        Divider()

        Button("contextMenu.develop") { actions.showDevelopPanel(photo) }
            .disabled(!availability.canDevelop)

        Button("contextMenu.rotate") { actions.rotate(photo) }

        Divider()

        Button("contextMenu.copyFileName") { actions.copyFileName(photo) }

        // iCloud写真のパスは eviction 対象の一時キャッシュを指すため項目自体を出さない
        if availability.canCopyPath {
            Button("contextMenu.copyPath") { actions.copyFilePath(photo) }
        }
    }

    private func successTagBinding(for tag: SuccessTagCategory) -> Binding<Bool> {
        Binding(
            get: { photo.successTags.contains(tag) },
            set: { _ in actions.toggleSuccessTag(photo, tag) }
        )
    }

    private var accessibilityLabelText: String {
        photo.isFavorite
            ? String(localized: "a11y.photo.favorite \(photo.displayFileName)")
            : photo.displayFileName
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
