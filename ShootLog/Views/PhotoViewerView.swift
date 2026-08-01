import SwiftUI
import AppKit

// 中央ビューア。回転（EditInfo.rotation）を適用して表示する
// Step1: サムネイル(512px)を即時表示 → Step2: フルサイズ画像に差し替え
struct PhotoViewerView: View {
    let photo: Photo?
    var editInfo: EditInfo? = nil
    @State private var vm = PhotoImageViewModel()

    var body: some View {
        Group {
            if let displayImage = vm.highRes ?? vm.thumbnail {
                ZStack(alignment: .bottomTrailing) {
                    rotatedImage(displayImage)
                        .accessibilityLabel(photo?.fileURL.lastPathComponent ?? "")
                    // サムネイル表示中かつ高解像度ロード待ちのときスピナーを右下に表示
                    if vm.highRes == nil && vm.isLoadingHighRes {
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
            await vm.load(photo: photo)
        }
    }

    // 90度/270度回転時はfit計算用のコンテナ幅高さを入れ替えてからrotationEffectを適用し、
    // レイアウト境界からのはみ出し（クリッピング）を防ぐ
    @ViewBuilder
    private func rotatedImage(_ image: NSImage) -> some View {
        let rotation = editInfo?.rotation ?? 0
        GeometryReader { geometry in
            let containerSize = geometry.size
            let isQuarterTurn = rotation % 180 != 0
            let fitSize = isQuarterTurn
                ? CGSize(width: containerSize.height, height: containerSize.width)
                : containerSize
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: fitSize.width, height: fitSize.height)
                .rotationEffect(.degrees(Double(rotation)))
                .frame(width: containerSize.width, height: containerSize.height)
        }
    }
}
