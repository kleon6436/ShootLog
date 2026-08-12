import SwiftUI
import AppKit

// 中央ビューア。回転（EditInfo.rotation）を適用して表示する。
// Step1: サムネイル（ImageLoaderの画質設定・既定768px）を即時表示 →
// Step2: 表示領域サイズに合わせてダウンサンプルした高解像度画像へ差し替え →
// Step3: 高倍率までズームしたときのみフルサイズデコード画像へ差し替え
struct PhotoViewerView: View {
    let photo: Photo?
    var editInfo: EditInfo? = nil

    // 前後1枚の先読み対象URL。呼び出し元が写真一覧を持つため、
    // URLの決定（先頭・末尾の境界処理を含む）は呼び出し元の責務とする
    var neighborPrefetchURLs: [URL] = []

    // 高倍率ズーム中かどうか。true の間だけフルサイズデコードした画像へ差し替える。
    // 倍率そのものではなくBoolを受け取るのは、ジェスチャー中の連続的な倍率変化で
    // 再デコードのタスクが張り替わり続けるのを避けるため
    var prefersFullSizeDecode: Bool = false

    // 補間品質。ズーム/パンのジェスチャー中は .medium へ落として拡大描画のコストを下げる
    var interpolation: Image.Interpolation = .high

    // 現在表示している画像のピクセルサイズを呼び出し元へ通知する。
    // フルスクリーンのズーム上限（実ロード済み解像度でのキャップ）とパンのクランプ計算に使う
    var onDisplayedImageSizeChange: ((CGSize) -> Void)? = nil

    @State private var vm = PhotoImageViewModel()

    // 高倍率ズーム用にフルサイズでデコードし直した画像。vm.highRes とは別に保持することで、
    // 再デコードが終わるまでダウンサンプル画像を表示し続けられる（差し替え時のちらつき防止）
    @State private var fullSizeImage: NSImage?

    // ズーム操作中の連続再デコードを避けるデバウンス時間
    private static let fullSizeDecodeDebounce = Duration.milliseconds(200)

    // 表示中の画像。フルサイズ > ダウンサンプル高解像度 > サムネイル の優先順で選ぶ
    private var displayImage: NSImage? {
        fullSizeImage ?? vm.highRes ?? vm.thumbnail
    }

    var body: some View {
        // 最外周の GeometryReader は表示領域サイズを初回ロードへ渡すために必要。
        // rotatedImage 内の GeometryReader は画像ロード後にしか存在せず、
        // 「どの解像度でデコードするか」の決定には使えない
        GeometryReader { geometry in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: photo?.id) {
                    // 前の写真のフルサイズ画像を残すと切替直後に別写真が見えてしまう
                    fullSizeImage = nil
                    await vm.load(photo: photo, displaySize: geometry.size)
                }
                // 先読みは表示中写真のロードとは別タスクにする。写真IDをキーに共有すると、
                // お気に入り絞り込みの切替で前後URLだけが変わった場合に古いURLのまま確定してしまう
                .task(id: neighborPrefetchURLs) {
                    await HighResPrefetcher.prefetch(urls: neighborPrefetchURLs)
                }
                .task(id: FullSizeDecodeKey(photoID: photo?.id, isEnabled: prefersFullSizeDecode)) {
                    await loadFullSizeIfNeeded()
                }
                // サムネイル→高解像度→フルサイズの差し替えでいずれも実解像度が変わるため、
                // すべての変化を通知する（フルスクリーンのズーム上限計算がこれに依存する）
                .onChange(of: vm.thumbnail, initial: true) { _, _ in notifyDisplayedImageSize() }
                .onChange(of: vm.highRes) { _, _ in notifyDisplayedImageSize() }
                .onChange(of: fullSizeImage) { _, _ in notifyDisplayedImageSize() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let displayImage {
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
                .interpolation(interpolation)
                .aspectRatio(contentMode: .fit)
                .frame(width: fitSize.width, height: fitSize.height)
                .rotationEffect(.degrees(Double(rotation)))
                .frame(width: containerSize.width, height: containerSize.height)
        }
    }

    // MARK: - フルサイズ再デコード

    // 高倍率ズーム時のみ、ダウンサンプルなしのフルサイズ画像へ差し替える。
    // 倍率が戻ったら破棄する：RAWのフルサイズ画像は1枚で数十MB規模になり、
    // 保持し続けると表示領域に応じたダウンサンプル化によるメモリ削減効果が失われるため
    private func loadFullSizeIfNeeded() async {
        guard prefersFullSizeDecode, let photo else {
            fullSizeImage = nil
            return
        }
        // しきい値を跨ぎ直すとこの .task が張り替わり、待機中にキャンセルされる。
        // 待機中は既存のダウンサンプル画像を表示し続けるためちらつかない
        try? await Task.sleep(for: Self.fullSizeDecodeDebounce)
        guard !Task.isCancelled else { return }
        let image = await ImageLoader.shared.highResImage(
            for: photo.fileURL,
            targetMaxPixelSize: ImageLoader.fullSizePixelTarget
        )
        // デコード中に写真が切り替わった場合の stale image 代入を防ぐ
        guard !Task.isCancelled else { return }
        fullSizeImage = image
    }

    // フルサイズデコードの要否を決めるキー。写真IDも含めることで、
    // 高倍率のまま写真が切り替わった場合にも再デコードを走らせる
    private struct FullSizeDecodeKey: Hashable {
        let photoID: UUID?
        let isEnabled: Bool
    }

    // MARK: - 実解像度の通知

    private func notifyDisplayedImageSize() {
        guard let onDisplayedImageSizeChange else { return }
        guard let displayImage else {
            onDisplayedImageSizeChange(.zero)
            return
        }
        onDisplayedImageSizeChange(Self.pixelSize(of: displayImage))
    }

    // NSImage.size はポイント単位（EXIF DPI により実ピクセルと一致しない）ため、
    // 表現（NSImageRep）から実ピクセル数を取得する
    private static func pixelSize(of image: NSImage) -> CGSize {
        guard let rep = image.representations.first else { return image.size }
        return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
    }
}
