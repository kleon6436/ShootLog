import SwiftUI
import AppKit

// 回転・トリミング表示に対応した写真ビューア（SidebarModeView の中央カラム用）
// Step1: サムネイル(512px)を即時表示 → Step2: フルサイズ画像に差し替え
struct EditablePhotoView: View {
    let photo: Photo?
    let editInfo: EditInfo?
    let isCropMode: Bool
    let onCropApply: (CGRect) -> Void
    let onCropCancel: () -> Void
    @State private var vm = PhotoImageViewModel()

    var body: some View {
        ZStack {
            if let image = vm.highRes ?? vm.thumbnail {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        // 回転を適用する（EditInfo に保存された値を使う）
                        .rotationEffect(.degrees(Double(editInfo?.rotation ?? 0)))

                    // サムネイル表示中かつ高解像度ロード待ちのときスピナーを右下に表示
                    if vm.highRes == nil && vm.isLoadingHighRes {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                    }
                }

                // トリミングモード時はオーバーレイを表示する
                if isCropMode {
                    CropOverlayView(
                        initialRect: editInfo?.cropRect ?? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                        onApply: onCropApply,
                        onCancel: onCropCancel
                    )
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
}
