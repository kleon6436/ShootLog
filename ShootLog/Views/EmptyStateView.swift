import SwiftData
import SwiftUI

// フォルダ未選択時の空状態ビュー。フォルダ履歴があれば一覧も表示する
struct EmptyStateView: View {
    var onOpenFolder: () -> Void
    var onOpenPhotosLibrary: () -> Void = {}
    var folderHistories: [FolderHistory] = []
    var onRestoreHistory: (FolderHistory) -> Void = { _ in }
    var onDeleteHistory: (FolderHistory) -> Void = { _ in }

    // 削除ボタンを表示する行。行の外へカーソルが出たら nil に戻す
    @State private var hoveredHistoryID: PersistentIdentifier?

    // 履歴行のアイコン square からファイル名までのインセット。Divider の leading と揃える
    private static let historyRowIconLeading: CGFloat = 12
    private static let historyRowIconSize: CGFloat = 30
    private static let historyRowContentGap: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // メインの空状態UI（HIGのContentUnavailableView相当の構成）
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(.quaternary.opacity(0.4))
                        .frame(width: 84, height: 84)
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Text("empty.title")
                        .font(.title2.weight(.bold))
                    Text("empty.subtitle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                HStack(spacing: 12) {
                    Button("empty.openFolder.button", action: onOpenFolder)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityLabel("common.openFolder")
                    Button("photosLibrary.openButton", action: onOpenPhotosLibrary)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityLabel("photosLibrary.openButton")
                }
            }

            // フォルダ履歴リスト
            if !folderHistories.isEmpty {
                Divider()
                    .padding(.vertical, 20)

                VStack(alignment: .leading, spacing: 8) {
                    Text("empty.recentFolders")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 0) {
                        ForEach(Array(folderHistories.enumerated()), id: \.element.persistentModelID) { index, history in
                            if index > 0 {
                                Divider()
                                    .padding(.leading, Self.historyRowIconLeading + Self.historyRowIconSize + Self.historyRowContentGap)
                            }
                            historyRow(history)
                        }
                    }
                    .contentCard(padding: 0)
                }
                .frame(width: 480)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // 履歴1行分。「開く」と「削除」は入れ子にせず兄弟として並べる。
    // Buttonのlabel内に別のButtonを置くとmacOSでヒットテストが期待どおりに動かないため
    private func historyRow(_ history: FolderHistory) -> some View {
        let isHovered = hoveredHistoryID == history.persistentModelID

        return HStack(spacing: Self.historyRowContentGap) {
            Button {
                onRestoreHistory(history)
            } label: {
                HStack(spacing: Self.historyRowContentGap) {
                    RoundedRectangle(cornerRadius: CornerRadius.medium)
                        .fill(Color.accentColor)
                        .frame(width: Self.historyRowIconSize, height: Self.historyRowIconSize)
                        .overlay {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.onAccent)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(history.displayName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(history.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Text(history.lastAccessedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("a11y.history.open \(history.displayName)")

            // シェブロンと削除ボタンは同じ末尾スロットを共有する（ホバーで置き換わって見える）。
            // 「開く」ボタンのlabel内に別のButtonを置くとmacOSでヒットテストが期待どおりに
            // 動かないため、ZStackで兄弟として重ね、削除ボタン自体は「開く」ボタンの外に置く
            ZStack {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 0 : 1)
                    .accessibilityHidden(true)

                Button {
                    onDeleteHistory(history)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .help("empty.history.delete.help")
                .accessibilityLabel("a11y.history.delete \(history.displayName)")
            }
            .frame(width: 20, height: 20)
        }
        .padding(.horizontal, Self.historyRowIconLeading)
        .frame(height: 52)
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredHistoryID = isHovering ? history.persistentModelID : nil
        }
    }
}

#Preview {
    EmptyStateView(onOpenFolder: {})
}
