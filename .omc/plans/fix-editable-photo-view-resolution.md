# メインビューア(SidebarMode)解像度修正プラン — 続報

**status:** pending approval
**作成日:** 2026-07-02
**対象フェーズ:** Phase 3（ImageLoader・Viewer）
**関連プラン:** `fix-viewer-resolution.md`（2026-06-29、`highResImage()` と `PhotoViewerView` を修正済み）

---

## 問題の要約（なぜ前回の修正で改善しなかったか）

前回プラン `fix-viewer-resolution.md` は `ImageLoader.highResImage(for:)` を
`NSImage(contentsOf:)` → `CGImageSourceCreateImageAtIndex` に修正し、`PhotoViewerView` を
サムネイル→高解像度の2段階ロードに変更した。この修正自体は正しく適用されている
（`ImageLoader.swift:64-91`、`PhotoViewerView.swift:38-50` で確認済み）。

**しかし `PhotoViewerView` は `FullscreenModeView` と `SlideshowModeView` からしか使われていない。**
アプリ起動時のデフォルトモード（`MainViewModel.swift:21`、`currentModeID = "sidebar"`）である
`SidebarModeView` の中央カラムは、別の型 `EditablePhotoView`（`SidebarModeView.swift:24`）を使っており、
こちらは今も

```swift
// EditablePhotoView.swift:40
image = await ImageLoader.shared.thumbnail(for: photo.fileURL)
```

**のみ**を呼んでおり、512px 上限のサムネイルを表示し続けている（`highResImage` 未使用）。
さらに `Image` に `.interpolation(.high)` も付いていない（`EditablePhotoView.swift:16-18`）。

つまりユーザーが実際に毎回見ている「メインで表示される画像」（サイドバーモードの中央ビューア）は
一度も修正されておらず、これが「何回か修正しているが改善が見られない」の原因である。
（旧プラン末尾の「将来の改善（範囲外）」に `EditablePhotoView` のフル解像度化が明記されており、
意図的にスコープ外にされていた）

`EditablePhotoView` の呼び出し元は `SidebarModeView.swift:24` の1箇所のみ（grep 済み）。影響範囲は限定的。

---

## 受け入れ条件

- [ ] デフォルト起動時（サイドバーモード）で写真を選択すると、最終的に `highResImage` 相当の解像度（RAWならセンサー解像度、JPEG/HEICなら原寸）で表示される
- [ ] 画像選択直後はサムネイルが即時表示され、その後シームレスに高解像度へ切り替わる（現状の白フラッシュ・ちらつきなし）
- [ ] `.interpolation(.high)` が適用され、拡大表示時のボケが `PhotoViewerView` と同等になる
- [ ] トリミングモード（`isCropMode = true`）中に画像がサムネイル→高解像度へ切り替わっても、`CropOverlayView` の矩形位置がズレない・リセットされない
- [ ] 写真を高速に連続切り替え（10枚）しても、古い写真の高解像度画像が新しい写真に一瞬表示されない（`Task.isCancelled` チェック）
- [ ] 回転表示（`editInfo?.rotation`）は高解像度画像でも従来通り機能する
- [ ] サムネイルグリッド・フルスクリーン・スライドショーの挙動・パフォーマンスに変化がない（`ImageLoader` 本体は無変更）

---

## 実装ステップ

### Step 1: `EditablePhotoView` を2段階ロード + 高解像度表示に変更

**ファイル:** `ShootLog/Features/Viewer/Views/EditablePhotoView.swift`

`PhotoViewerView.swift:9-11, 38-50` と同じパターンを移植する。`image: NSImage?` を
`thumbnail`/`highRes`/`isLoadingHighRes` の3状態に分割し、`.task` を2段階化。
`Image` に `.interpolation(.high)` を追加。

```swift
struct EditablePhotoView: View {
    let photo: Photo?
    let editInfo: EditInfo?
    let isCropMode: Bool
    let onCropApply: (CGRect) -> Void
    let onCropCancel: () -> Void
    @State private var thumbnail: NSImage?
    @State private var highRes: NSImage?
    @State private var isLoadingHighRes = false

    var body: some View {
        ZStack {
            if let image = highRes ?? thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(.degrees(Double(editInfo?.rotation ?? 0)))

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
            thumbnail = nil
            highRes = nil
            isLoadingHighRes = false
            guard let photo else { return }
            thumbnail = await ImageLoader.shared.thumbnail(for: photo.fileURL)
            guard !Task.isCancelled else { return }
            isLoadingHighRes = true
            highRes = await ImageLoader.shared.highResImage(for: photo.fileURL)
            isLoadingHighRes = false
        }
    }
}
```

（ロード中スピナーのオーバーレイは `PhotoViewerView.swift:23-28` と同様に追加してよいが必須ではない。
`isCropMode` のオーバーレイ表示ロジックとスピナーが重ならないよう `ZStack` の順序に注意）

### Step 2: クロップモードとの整合性確認

`CropOverlayView` の `initialRect` は正規化座標（0.0〜1.0）で `editInfo?.cropRect` に依存しており、
`NSImage` のピクセル寸法そのものには依存しないため、サムネイル→高解像度の切り替えでズレは起きない想定。
ただし `highRes` 到着時に `ZStack` 内の `Image` が差し替わることで `CropOverlayView` が再生成され、
編集中の未確定ドラッグ状態がリセットされる可能性がある。実機確認で許容範囲か判断する（Step 1のスピナー同様、
`isCropMode` 中は `highRes` 差し替えを止める案もあるが、まずは差し替えたまま実機確認し、問題があれば
`isCropMode` 中のみ `thumbnail` を固定表示するガードを追加する）。

---

## リスクと対策

| リスク | 対策 |
|---|---|
| クロップ中の画像差し替えで `CropOverlayView` のドラッグ状態がリセットされる | Step 2で実機確認。問題があれば `isCropMode` 中は高解像度差し替えを保留するガードを追加 |
| 高解像度ロード中のちらつき・レイアウトジャンプ | サムネイルを高解像度到着まで表示し続ける（`highRes ?? thumbnail`）ので発生しない想定 |
| 巨大RAW（60MP等）でのメモリ増加 | `ImageLoader.highResCache` は既存の `NSCache`（自動エビクション）を再利用するため追加変更不要 |

---

## 検証ステップ

1. アプリ起動（デフォルトのサイドバーモード）でRAW写真（NEF/ARW/CR3等）を選択し、拡大表示してボケがないことを目視確認
2. `po highRes?.size` 相当で表示中画像のピクセル寸法を確認 → センサー解像度と一致するか
3. トリミングモードに入り、矩形をドラッグしている最中に高解像度画像へ切り替わっても矩形位置が保持されることを確認
4. 写真を高速に10枚切り替え、最終写真に別写真が一瞬表示されないことを確認
5. 回転を設定した写真を選択し、高解像度画像でも回転が正しく適用されることを確認
6. フルスクリーン・スライドショーモード（`PhotoViewerView` 経由）の表示・切り替え挙動に変化がないことを確認（回帰確認）

---

## 変更ファイルサマリー

| ファイル | 変更箇所 | 変更内容 |
|---|---|---|
| `Features/Viewer/Views/EditablePhotoView.swift` | 全体 | `thumbnail`単発ロード → `thumbnail`→`highRes`2段階ロードに変更、`.interpolation(.high)` 追加 |

`ImageLoader.swift` / `PhotoViewerView.swift` は変更不要（前回プランで既に対応済み）。
