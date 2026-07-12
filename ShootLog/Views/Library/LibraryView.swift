import SwiftUI
import AppKit

// 写真グリッドビュー。Phase 5 で SidebarModeView に統合される
struct LibraryView: View {
    var folderURL: URL
    @State private var vm = LibraryViewModel()
    @Environment(\.modelContext) private var modelContext
    @State private var noteEditorTarget: Photo?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 4)]

    var body: some View {
        Group {
            if vm.isScanning {
                ProgressView("スキャン中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.scanError {
                ContentUnavailableView {
                    Label("読み込みエラー", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                }
            } else if vm.photos.isEmpty {
                ContentUnavailableView {
                    Label("写真が見つかりません", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("対応フォーマット（RAW / JPEG / HEIC / PNG 等）の写真がありません")
                }
            } else {
                photoGrid
            }
        }
        .navigationTitle(folderURL.lastPathComponent)
        .overlay(alignment: .bottom) {
            // トースト（お気に入り登録など一時通知）
            if let toast = vm.toastMessage {
                ToastView(message: toast)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.toastMessage)
        .sheet(item: $noteEditorTarget) { photo in
            NoteEditorSheet(photo: photo) { note in
                vm.saveNote(note, for: photo)
            }
        }
        .task(id: folderURL) {
            vm.configure(context: modelContext)
            await vm.loadFolder(folderURL)
        }
        .onChange(of: vm.selectedPhoto) { _, photo in
            guard let photo else { return }
            Task { await vm.loadEXIFIfNeeded(for: photo) }
        }
    }

    // MARK: - Private

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(vm.photos) { photo in
                    ThumbnailCell(
                        photo: photo,
                        isSelected: vm.selectedPhoto?.id == photo.id
                    ) {
                        vm.selectedPhoto = photo
                    } onToggleFavorite: {
                        vm.toggleFavorite(photo)
                    } onEditNote: {
                        noteEditorTarget = photo
                    }
                }
            }
            .padding(8)
        }
        .overlay(alignment: .bottom) {
            HStack {
                Spacer()
                Text("\(vm.photos.count) 枚")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassOrMaterialCapsule()
                    .padding(8)
            }
        }
    }
}

// MARK: - ThumbnailCell

private struct ThumbnailCell: View {
    let photo: Photo
    let isSelected: Bool
    let onTap: () -> Void
    let onToggleFavorite: () -> Void
    let onEditNote: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // サムネイル or プレースホルダー
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .overlay { ProgressView().scaleEffect(0.65) }
                }
            }
            .frame(width: 110, height: 110)
            .clipped()

            // お気に入りバッジ
            if photo.isFavorite {
                Image(systemName: "star.fill")
                    // LibraryViewはライト/ダーク適応の通常グリッドであり黒背景HUDではないため、
                    // 固定サイズのHUDTypographyではなくDynamic Typeの.caption2を使う
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .elevation(.card)
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: CornerRadius.small)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button {
                onToggleFavorite()
            } label: {
                Label(
                    photo.isFavorite ? "お気に入りを解除" : "お気に入りに追加",
                    systemImage: photo.isFavorite ? "star.slash" : "star"
                )
            }
            Button {
                onEditNote()
            } label: {
                Label("メモを編集", systemImage: "pencil")
            }
            Divider()
            Menu("外部アプリで開く") {
                ForEach(ExternalAppRegistry.shared.availableAdapters, id: \.id) { adapter in
                    Button {
                        adapter.open(url: photo.fileURL)
                    } label: {
                        Label(adapter.displayName, systemImage: adapter.symbolName)
                    }
                }
            }
        }
        .accessibilityLabel(photo.fileURL.lastPathComponent)
        .task { thumbnail = await ImageLoader.shared.thumbnail(for: photo.fileURL) }
    }
}

// MARK: - NoteEditorSheet

private struct NoteEditorSheet: View {
    let photo: Photo
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(photo: Photo, onSave: @escaping (String) -> Void) {
        self.photo = photo
        self.onSave = onSave
        self._text = State(initialValue: photo.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(photo.fileURL.lastPathComponent)
                .font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.medium)
                        .strokeBorder(Color.secondary.opacity(0.3))
                }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
        .accessibilityLabel("メモを編集")
    }
}

#Preview {
    LibraryView(folderURL: URL(fileURLWithPath: NSHomeDirectory()))
}
