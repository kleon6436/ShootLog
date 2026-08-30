import SwiftUI
import AppKit

// 回転・トリミング表示に対応した写真ビューア（SidebarModeView の中央カラム用）
// Step1: サムネイル（ImageLoaderの画質設定・既定768px）を即時表示 →
// Step2: 表示領域サイズに合わせてダウンサンプルした高解像度画像へ差し替え
struct EditablePhotoView: View {
    let photo: Photo?
    let editInfo: EditInfo?
    let isCropMode: Bool
    // 現像プレビュー。previewImage があればベース画像の代わりに表示する
    let developViewModel: DevelopViewModel
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
            content(containerSize: geometry.size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    DisplayColorSpaceReader { developViewModel.setPreviewColorSpace($0) }
                )
                .task(id: photo?.id) {
                    await vm.load(photo: photo, displaySize: geometry.size)
                    // 現像 VM も同じ選択経路で追従させる（キーボード送り・絞り込み切替を含む）。
                    // 回転・トリミングもプレビューへ焼き込むため EditInfo を渡す
                    developViewModel.load(
                        photo: photo,
                        displaySize: geometry.size,
                        rotation: editInfo?.rotation ?? 0,
                        cropRect: editInfo?.cropRect
                    )
                }
                .onChange(of: geometry.size) { _, newSize in
                    developViewModel.updateDisplaySize(newSize)
                }
                .onChange(of: editInfo?.rotation ?? 0) { _, newRotation in
                    developViewModel.updateEditGeometry(rotation: newRotation, cropRect: editInfo?.cropRect)
                }
                .onChange(of: editInfo?.cropRect) { _, newCrop in
                    developViewModel.updateEditGeometry(rotation: editInfo?.rotation ?? 0, cropRect: newCrop)
                }
                // 先読みは表示中写真のロードとは別タスクにする。写真IDをキーに共有すると、
                // お気に入り絞り込みの切替で前後URLだけが変わった場合に古いURLのまま確定してしまう
                .task(id: neighborPrefetchURLs) {
                    await HighResPrefetcher.prefetch(urls: neighborPrefetchURLs)
                }
        }
    }

    @ViewBuilder
    private func content(containerSize: CGSize) -> some View {
        // 従来の 2 段階ロード結果。トリミングオーバーレイの基準と、現像プレビュー未生成時の表示に使う。
        let baseImage = vm.highRes ?? vm.thumbnail
        // 現像プレビューは回転・トリミング焼き込み済み。トリミングモード中はベース全体を見せるため使わない。
        let developPreview = isCropMode ? nil : developViewModel.previewImage

        ZStack {
            if let displayImage = developPreview ?? baseImage {
                ZStack(alignment: .bottomTrailing) {
                    if developPreview != nil {
                        // 焼き込み済み。二重回転を避けてそのまま aspect-fit で表示する
                        Image(nsImage: displayImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // ベース画像は EditInfo の回転を rotationEffect で適用する
                        rotatedImage(displayImage)
                    }

                    if spinnerVisible {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                    }
                }

                // トリミングモード時はオーバーレイを表示する。
                // 正規化の基準は回転後に表示されている画像の矩形（レターボックスを除く）。
                if isCropMode, let baseImage {
                    CropOverlayView(
                        initialRect: editInfo?.cropRect ?? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                        // rotatedImage は baseImage.size を基準に aspect-fit しているので、
                        // オーバーレイの基準も同じ値を使わないと矩形がずれる。
                        imageFrame: CropViewModel.displayedImageFrame(
                            imagePixelSize: baseImage.size,
                            rotation: editInfo?.rotation ?? 0,
                            in: containerSize
                        ),
                        onApply: onCropApply,
                        onCancel: onCropCancel
                    )
                }
            } else if photo != nil {
                ProgressView()
            } else {
                Text("viewer.selectPhoto")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // 現像レンダリング中、またはサムネイル表示中で高解像度ロード待ちのときスピナーを出す
    private var spinnerVisible: Bool {
        developViewModel.isRendering
            || (developViewModel.previewImage == nil && vm.highRes == nil && vm.isLoadingHighRes)
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
