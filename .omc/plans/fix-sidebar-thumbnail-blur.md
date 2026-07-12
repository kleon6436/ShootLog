# サイドバー（左サムネイル一覧）ぼやけ修正プラン

**Status:** pending approval
**Mode:** Direct（バグ報告 + ユーザー確認で範囲確定：左サムネイル一覧自体）

---

## Requirements Summary

サイドバー（`SidebarModeView` → `PhotoListView` の `PhotoGridCell`）でサムネイルが常にぼやけて見える。
スクロールしても高解像度化されない。原因調査の結果、**中央ビューア（`EditablePhotoView`）ではなく左サムネイル一覧自体**の問題と確認済み（ユーザー回答）。

---

## 現状（コード調査結果）

- `ShootLog/Services/ImageLoader.swift:108-134` `loadCGThumbnail(from:)` — 埋め込みサムネイル優先パス（119行目）・フルサイズfallbackパス（130行目）の両方で `kCGImageSourceThumbnailMaxPixelSize: 512` を使用。**長辺のみ**を512pxに制限する。
- `ShootLog/Features/Library/Views/PhotoListView.swift:10` — グリッドセル幅は `GridItem(.adaptive(minimum: 110, maximum: 240))` で最大240pt。
- 同ファイル41行目 `.aspectRatio(3/2, contentMode: .fit)` でセルは3:2の横長boxに固定（240pt幅時、高さ160pt）。Retina 2倍換算で **480×320px**。
- 同ファイル85行目 `thumbnailView` は `.aspectRatio(contentMode: .fill)` — サムネイルをboxいっぱいに**クロップ表示**する。

**根本原因**：`kCGImageSourceThumbnailMaxPixelSize` は画像の**長辺のみ**を制限する。横位置（ランドスケープ）写真なら512px長辺のサムネイルは480×320boxとほぼ一致し問題ないが、**縦位置（ポートレート）写真**では長辺（高さ）が512pxに制限された結果、短辺（幅）は 512×(2/3)≈341px にしかならない。これを480×320の横長boxに `.fill` でクロップ表示すると、幅方向で 480/341 ≈ **1.4倍に引き伸ばされ**、明確なぼやけが発生する。

過去の `.omc/plans/resizable-sidebar-thumbnail-grid.md`（29行目）では「240pt表示（Retinaで480px相当）は既存の512pxデコード予算内に収まる→ImageLoader変更不要」と判断していたが、これは**横位置写真のみを想定した見落とし**だった。縦位置写真とfillクロップの組み合わせを考慮していなかった。

**必要な値の算出**：ポートレート写真（想定アスペクト比 2:3）の短辺が480px以上になるには、
`maxPixelSize × (2/3) ≥ 480` → `maxPixelSize ≥ 720`。余裕を持たせて **768px** を採用する。

---

## Acceptance Criteria

1. `ImageLoader.loadCGThumbnail` の埋め込み優先パス（119行目）・フルサイズfallbackパス（130行目）の両方で `kCGImageSourceThumbnailMaxPixelSize` が同一の定数（768）を参照している（コード確認、2箇所の値が将来ズレないよう定数化されている）。
2. ディスクサムネイルキャッシュのディレクトリ名が `thumbnails-v2` → `thumbnails-v3` に変更されている（`ImageLoader.swift:150-153`）。旧512pxキャッシュが誤って再利用されないことをコードで確認。
3. 縦位置（ポートレート）写真をサイドバー2列表示（240pt幅セル）で表示したとき、目視で明確なぼやけがない（Retinaディスプレイ実機確認）。
4. 横位置（ランドスケープ）写真も引き続きシャープに表示される（回帰なし、実機確認）。
5. 中央ビューア（`EditablePhotoView`）のStep1プレースホルダー表示（`thumbnail()` を共用）が悪化しない、むしろ改善する（同関数を使うため自動的に恩恵を受ける、実機確認）。
6. ビルドが成功し、SwiftLintの新規違反（`force_unwrapping`等）が増えていない。
7. サムネイル取得のスクロール中のパフォーマンス体感が悪化しない（512→768pxは緩やかな増加、実機でスクロール時のカクつきがないことを確認）。

---

## Implementation Steps

### Step 1 — サムネイル最大解像度を768pxに引き上げ、定数化

**File:** `ShootLog/Services/ImageLoader.swift`

- クラス内に定数を追加：
  ```swift
  // グリッドセル最大240pt(Retina 2倍=480px)の横長box(3:2)に、
  // 縦位置写真をfillクロップ表示しても短辺が480pxを下回らないための値
  // (768 × 2/3 ≈ 512 > 480、余裕を持たせて768に設定)
  private static let thumbnailMaxPixelSize = 768
  ```
- 119行目 `kCGImageSourceThumbnailMaxPixelSize: 512` → `kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize` に変更。
- 130行目 `kCGImageSourceThumbnailMaxPixelSize: 512` → 同様に変更（fallbackパスも必ず同じ値にする。2箇所が別々の値になっていたのが将来のバグの元になるため定数化で防止）。

### Step 2 — ディスクキャッシュのバージョンを上げて旧512pxキャッシュを無効化

**File:** `ShootLog/Services/ImageLoader.swift:150-153`

```swift
// ~/Library/Caches/com.shootlog.app/thumbnails-v3/（v3=768px上限、v2の512pxキャッシュを無効化）
static let diskCacheDir: URL = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("com.shootlog.app/thumbnails-v3", isDirectory: true)
}()
```

旧 `thumbnails-v2` ディレクトリは自動削除しない（v1→v2移行時と同じ方針、ディスク容量への影響は軽微）。

### Step 2.5 — グリッドセルの補間品質を`.high`に設定（追加修正）

**File:** `ShootLog/Features/Library/Views/PhotoListView.swift:83-85`

ユーザー確認により768px化だけでは解消せず、`PhotoGridCell.thumbnailView`の`Image`に`.interpolation(.high)`が付与されていなかったことが判明（SwiftUIのデフォルト補間は`.medium`）。`EditablePhotoView.swift:22`で既に採用済みの設定を踏襲。

```swift
Image(nsImage: thumbnail)
    .resizable()
    .interpolation(.high)
    .aspectRatio(contentMode: .fill)
```

### Step 3 — 動作確認

- `run` スキル、または手動でアプリを起動。
- 縦位置・横位置が混在するフォルダ（RAW+JPEG）を開く。
- サイドバーを2列表示になる幅までドラッグで広げ、縦位置写真のぼやけが解消されていることを目視確認。
- 中央ビューアでプレースホルダー表示（サムネイル→高解像度切替の前段階）も鮮明になっていることを確認。
- ライト/ダークモード切替で見た目に問題がないか確認。

---

## Risks and Mitigations

| リスク | 対策 |
|--------|------|
| メモリ・ディスクキャッシュ使用量が微増する（768pxは512pxよりやや大きい） | 写真管理アプリの用途上許容範囲。必要になれば`NSCache.totalCostLimit`調整を別タスクで検討（フォローアップ） |
| 旧`thumbnails-v2`ディレクトリがディスクに残り続ける | v1→v2移行時と同じ既存方針を踏襲。影響は軽微なディスク容量のみ |
| 768pxでも極端なアスペクト比（超ワイドパノラマ等）では理論上まだ不足しうる | 一般的な写真アスペクト比（2:3〜3:2程度）を想定した現実的な値。極端なケースへの対応は今回スコープ外 |
| 埋め込みサムネイルが768pxより小さいカメラ機種がある | ImageIOは要求サイズより小さい埋め込みプレビューしか無ければそのまま返す（現状と同じ挙動、悪化しない） |

---

## Verification Steps

1. `xcodebuild build`（または Xcode上）でコンパイルエラーがないことを確認。
2. `run` スキルでアプリを起動し、Acceptance Criteria 3〜5を実機で目視確認。
3. SwiftLintを実行し、新規違反がないことを確認。
4. ライト/ダークモード両方で見た目を確認。

---

## Out of Scope（今回スコープ外）

- 中央ビューア（`EditablePhotoView`）の thumbnail→highRes 2段階ロード自体の修正（`fix-viewer-resolution.md` で既に対応済み。ユーザー確認により今回のバグは左一覧自体の問題と特定）。
- `LibraryView.swift` の未使用重複グリッドコード整理（`resizable-sidebar-thumbnail-grid.md` 同様、Phase5統合まで据え置き）。
- `NSCache.totalCostLimit` の動的設定。
