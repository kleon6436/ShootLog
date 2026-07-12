# メインビューア 解像度修正プラン

**status:** pending approval  
**作成日:** 2026-06-29  
**対象フェーズ:** Phase 3（ImageLoader・Viewer）

---

## 問題の要約

`PhotoViewerView` はサムネイル(512px) → `highResImage` の差し替え構造で正しいが、
`highResImage(for:)` が `NSImage(contentsOf:)` を使用しているため、RAW ファイル（NEF/ARW/CR3/RAF/DNG）で
macOS が埋め込み JPEG プレビュー（1.5〜5MP 程度）を返す場合がある。
センサー解像度（20〜60MP）とかけ離れた画像が表示されている可能性が高い。

---

## 受け入れ条件

- [ ] Nikon NEF / Sony ARW / Canon CR3 / Sigma DNG を開いたとき、`highRes` の pixel width がセンサー幅（≥3000px）と一致する
- [ ] JPEG / HEIC / TIFF は引き続き正常表示される
- [ ] サムネイルグリッドのパフォーマンスは変化しない（`thumbnail()` 関数は無変更）
- [ ] メインビューアがサムネイル→高解像度に切り替わるとき、ロード中インジケーターが見える
- [ ] `.task` がキャンセルされた場合（写真切り替え時）、古い高解像度画像が新しい写真に表示されない

---

## 実装ステップ

### Step 1: `ImageLoader.highResImage(for:)` を `CGImageSourceCreateImageAtIndex` に置き換え

**ファイル:** `ShootLog/Services/ImageLoader.swift:63-83`

**変更内容:**

```swift
// メインビューア用：フルサイズ画像を返す（メモリ→CGImageSource の順で確認）
// NSImage(contentsOf:) は RAW ファイルで埋め込み JPEG を返すことがあるため、
// CGImageSourceCreateImageAtIndex でフルセンサー解像度を明示的に取得する
func highResImage(for url: URL) async -> NSImage? {
    let key = url as NSURL

    if let img = highResCache.object(forKey: key) { return img }

    let isNetwork = volumeIsNetwork(url)
    if isNetwork { await throttle.acquire() }

    let image = await Task.detached(priority: .utility) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        // kCGImageSourceShouldCacheImmediately: false でデコード前のメモリ確保を抑制する
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil as NSImage? }

        // nil オプションで全フルサイズデコード（埋め込み JPEG を使わない）
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil as NSImage? }

        // size: .zero は NSImage が CGImage のピクセル寸法を 1pt=1px で採用する
        return NSImage(cgImage: cgImage, size: .zero)
    }.value

    if isNetwork { await throttle.release() }
    guard let image else { return nil }

    highResCache.setObject(image, forKey: key)
    return image
}
```

**理由:** `CGImageSourceCreateImageAtIndex(source, 0, nil)` は ImageIO が RAW をフルデコードする確実なパス。
`NSImage(contentsOf:)` は内部で異なる NSImageRep を選択することがあり、RAW で embedded JPEG を優先する。

---

### Step 2: SwiftUI Image の補間品質を `high` に設定

**ファイル:** `ShootLog/Features/Viewer/Views/PhotoViewerView.swift:15-17`

```swift
Image(nsImage: displayImage)
    .resizable()
    .interpolation(.high)          // 追加: 高品質ダウンスケール
    .aspectRatio(contentMode: .fit)
    .rotationEffect(.degrees(Double(editInfo?.rotation ?? 0)))
    .accessibilityLabel(photo?.fileURL.lastPathComponent ?? "")
```

**理由:** SwiftUI のデフォルト補間は `.medium`。高解像度 RAW を画面サイズにフィットさせる際に精細感が落ちる。

---

### Step 3: `.task` にキャンセルチェックを追加

**ファイル:** `ShootLog/Features/Viewer/Views/PhotoViewerView.swift:28-35`

```swift
.task(id: photo?.id) {
    thumbnail = nil
    highRes = nil
    guard let photo else { return }
    thumbnail = await ImageLoader.shared.thumbnail(for: photo.fileURL)
    // サムネイル取得後に写真が切り替わっていたら高解像度ロードをスキップする
    guard !Task.isCancelled else { return }
    highRes = await ImageLoader.shared.highResImage(for: photo.fileURL)
}
```

**理由:** 写真を素早くクリックすると旧タスクが継続し、`highRes` に別の写真の画像が一瞬表示される可能性がある。

---

### Step 4: ロード中インジケーター（高解像度待機中）

**ファイル:** `ShootLog/Features/Viewer/Views/PhotoViewerView.swift`

```swift
@State private var thumbnail: NSImage?
@State private var highRes: NSImage?
@State private var isLoadingHighRes = false   // 追加

var body: some View {
    Group {
        if let displayImage = highRes ?? thumbnail {
            ZStack {
                Image(nsImage: displayImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(.degrees(Double(editInfo?.rotation ?? 0)))
                    .accessibilityLabel(photo?.fileURL.lastPathComponent ?? "")
                // サムネイル表示中かつ高解像度ロード待ちのときスピナーを右下に表示
                if thumbnail != nil && highRes == nil && isLoadingHighRes {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                        }
                    }
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
```

---

## リスクと軽減策

| リスク | 内容 | 軽減策 |
|--------|------|--------|
| メモリ使用量増加 | フルサイズ RAW は 50MB超になる場合あり | `highResCache` の `totalCostLimit` を設定（例: 200MB） |
| 初回ロード時間 | RAW フルデコードは 1〜3秒かかる | Step 4 のスピナーでユーザーに明示 |
| JPEG/HEIC への影響 | `CGImageSourceCreateImageAtIndex` に変更しても JPEG は問題なし | ✅ ImageIO が JPEG/HEIC も正しく処理する |
| `NSImage` の DPI | `size: .zero` で CGImage のピクセル寸法が 1pt=1px で採用される | Retina 環境での確認が必要（別途 Step 5 で対応可能） |

---

## 検証ステップ

1. Nikon NEF ファイルを開き、Xcode の `po displayImage.size` でピクセル寸法を確認 → センサー解像度と一致するか
2. Sony ARW / Canon CR3 で同様に確認
3. JPEG を開き、表示が正常であることを確認
4. 写真を素早く10枚切り替え → 最終写真に別写真の画像が一瞬出ないことを確認
5. ネットワークドライブ（またはローカル）で大きな RAW を開き、スピナーが出てから高解像度に切り替わることを確認

---

## 変更ファイルサマリー

| ファイル | 変更箇所 | 変更内容 |
|---------|---------|---------|
| `Services/ImageLoader.swift:63-83` | `highResImage(for:)` | `NSImage(contentsOf:)` → `CGImageSourceCreateImageAtIndex` |
| `Features/Viewer/Views/PhotoViewerView.swift:14-36` | `body` + `.task` | `.interpolation(.high)` 追加・キャンセルチェック・スピナー |

---

## 将来の改善（このプランの範囲外）

- `highResCache` の `totalCostLimit` をメモリ容量に応じて動的設定
- `EditablePhotoView`（クロップエディタ）も同様にフル解像度化
- Retina ディスプレイ対応: `NSScreen.main?.backingScaleFactor` を考慮した `NSImage` サイズ設定
