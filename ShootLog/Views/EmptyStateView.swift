import SwiftData
import SwiftUI

// フォルダ未選択時の空状態ビュー。フォルダ履歴があれば一覧も表示する
struct EmptyStateView: View {
    var onOpenFolder: () -> Void
    var folderHistories: [FolderHistory] = []
    var onRestoreHistory: (FolderHistory) -> Void = { _ in }
    var onDeleteHistory: (FolderHistory) -> Void = { _ in }

    // 削除ボタンを表示する行。行の外へカーソルが出たら nil に戻す
    @State private var hoveredHistoryID: PersistentIdentifier?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // メインの空状態UI
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("empty.title")
                    .font(.title3).fontWeight(.medium)
                Text("empty.subtitle")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("empty.openFolder.button", action: onOpenFolder)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("common.openFolder")
            }

            // フォルダ履歴リスト
            if !folderHistories.isEmpty {
                Divider()
                    .padding(.vertical, 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text("empty.recentFolders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    // 「開く」と「削除」は入れ子にせず兄弟として並べる。
                    // Buttonのlabel内に別のButtonを置くとmacOSでヒットテストが期待どおりに動かないため
                    ForEach(folderHistories) { history in
                        HStack(spacing: 4) {
                            Button {
                                onRestoreHistory(history)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(history.displayName)
                                            .font(.body)
                                        Text(history.url.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("a11y.history.open \(history.displayName)")

                            // ホバー時のみ見えるが、レイアウトとアクセシビリティツリーには常に残す
                            // （if で出し分けると行幅が動き、VoiceOverからも到達できなくなるため）
                            Button {
                                onDeleteHistory(history)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .opacity(hoveredHistoryID == history.persistentModelID ? 1 : 0)
                            .help("empty.history.delete.help")
                            .accessibilityLabel("a11y.history.delete \(history.displayName)")
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        // 履歴行はコンテンツ層のため Material ではなく塗りで区切る
                        // （ライトモードでウィンドウ背景と同化して境界が消えるのを防ぐ）
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
                        .onHover { isHovering in
                            hoveredHistoryID = isHovering ? history.persistentModelID : nil
                        }
                    }
                }
                .frame(maxWidth: 400)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    EmptyStateView(onOpenFolder: {})
}
