import SwiftUI
import AppKit

// 中央ビューア。回転（EditInfo.rotation）を適用して表示する
// Step1: サムネイル(512px)を即時表示 → Step2: フルサイズ画像に差し替え
struct PhotoViewerView: View {
    let photo: Photo?
    var editInfo: EditInfo? = nil
    @State private var thumbnail: NSImage?
    @State private var highRes: NSImage?
    @State private var isLoadingHighRes = false

    var body: some View {
        Group {
            if let displayImage = highRes ?? thumbnail {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: displayImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(editInfo?.rotation ?? 0)))
                        .accessibilityLabel(photo?.fileURL.lastPathComponent ?? "")
                    // サムネイル表示中かつ高解像度ロード待ちのときスピナーを右下に表示
                    if highRes == nil && isLoadingHighRes {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                    }
                }
            } else if photo != nil {
                ProgressView()
            } else {
                Text("写真を選択してください")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: photo?.id) {
            // 前の写真の残像をクリアしてから新しい写真をロード
            thumbnail = nil
            highRes = nil
            isLoadingHighRes = false
            guard let photo else { return }
            thumbnail = await ImageLoader.shared.thumbnail(for: photo.fileURL)
            // サムネイル取得後に写真が切り替わっていたら高解像度ロードをスキップする
            guard !Task.isCancelled else { return }
            isLoadingHighRes = true
            highRes = await ImageLoader.shared.highResImage(for: photo.fileURL)
            isLoadingHighRes = false
        }
    }
}
