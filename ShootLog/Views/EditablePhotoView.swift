import SwiftUI
import AppKit

// 回転・トリミング表示に対応した写真ビューア（SidebarModeView の中央カラム用）
// Step1: サムネイル（ImageLoaderの画質設定・既定768px）を即時表示 →
// Step2: 表示領域サイズに合わせてダウンサンプルした高解像度画像へ差し替え
struct EditablePhotoView: View {
    let photo: Photo?
    let editInfo: EditInfo?
    let isCropMode: Bool
    // 前後1枚の先読み対象URL。URLの決定（先頭・末尾の境界処理を含む）は呼び出し元の責務とする
    var neighborPrefetchURLs: [URL] = []
    let onCropApply: (CGRect) -> Void
    let onCropCancel: () -> Void
    @State private var vm = PhotoImageViewModel()

    var body: some View {
        // 最外周の GeometryReader は表示領域サイズを初回ロードへ渡すために必要。
        // rotatedImage 内の GeometryReader は画像ロード後にしか存在せず、
        // 「どの解像度でデコードするか」の決定には使えない
        GeometryReader { geometry in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: photo?.id) {
                    await vm.load(photo: photo, displaySize: geometry.size)
                }
                // 先読みは表示中写真のロードとは別タスクにする。写真IDをキーに共有すると、
                // お気に入り絞り込みの切替で前後URLだけが変わった場合に古いURLのまま確定してしまう
                .task(id: neighborPrefetchURLs) {
                    await HighResPrefetcher.prefetch(urls: neighborPrefetchURLs)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let image = vm.highRes ?? vm.thumbnail {
                ZStack(alignment: .bottomTrailing) {
                    // 回転を適用する（EditInfo に保存された値を使う）
                    rotatedImage(image)

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
