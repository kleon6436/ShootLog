# サイドバー可変幅化＋サムネイルグリッド表示

**Status:** pending approval
**Mode:** Direct（要件確認済み・3問インタビュー実施）

---

## Requirements Summary

Capture One のように、サイドバー（左カラム＝写真一覧）の幅をドラッグで可変にし、幅が増えたらサムネイルを大きく・2列表示に自動切替する。

インタビューで確定した仕様：

| 項目 | 決定 |
|------|------|
| 1列/2列切替 | 幅の閾値で自動切替（SwiftUI `LazyVGrid` の adaptive 挙動に一任、手動トグル無し） |
| 幅の可変範囲 | 120〜400pt |
| サムネイル最大サイズ | 約240px |
| 幅の永続化 | あり（`@AppStorage` で次回起動時に復元） |

対象は現行の**サイドバーモード**（`SidebarModeView` → `PhotoListView`）のみ。`LibraryView.swift`（Phase5統合待ちの未使用グリッドコード、110〜160px）は対象外（現状どこからも参照されておらず、今回のスコープ外。将来の重複コード整理は別タスク）。

---

## 現状（Explore調査結果）

- `ShootLog/Features/Viewer/Views/SidebarModeView.swift:12` — 左カラム幅固定 `.navigationSplitViewColumnWidth(min: 120, ideal: 140, max: 200)`。可変幅ではあるが範囲が狭く2列は入らない。
- `ShootLog/Features/Library/Views/PhotoListView.swift:1-64` — `List(selection:)` による単一列表示。`PhotoListRow`（22-64行目）が1行1サムネイル（アスペクト比3:2, `.frame(maxWidth: .infinity)`）。グリッドではない。
- `ShootLog/Services/ImageLoader.swift:119,130` — サムネイルは既に `kCGImageSourceThumbnailMaxPixelSize: 512` でデコード済み。240pt表示（Retinaで480px相当）は既存デコード予算内に収まる → **ImageLoader変更不要**。
- レイアウト状態（列数・サムネイルサイズ・サイドバー幅）を持つ ViewModel プロパティは存在しない（`MainViewModel` 含め皆無）。
- `@AppStorage` / `UserDefaults` の使用例はコードベースに一切なし。`Features/Settings/` は空ディレクトリ。永続化の仕組みをゼロから導入する。
- `GeometryReader` の使用例は `CropOverlayView.swift:20` のみ。`LazyVGrid`/`GridItem` は `LibraryView.swift`（未使用系統）のみ。

---

## 技術的制約（重要）

SwiftUI の `NavigationSplitView` には、ユーザーがドラッグした**実際の列幅を読み取る公開API（バインディング）が存在しない**。`.navigationSplitViewColumnWidth(min:ideal:max:)` は初期レイアウト用の制約値を与えるだけで、ドラッグ後の幅を直接取得できない。

**採用する回避策**：左カラムのコンテンツを `GeometryReader` でラップし、実際に描画された幅（`geometry.size.width`）を監視 → デバウンスして `@AppStorage` に保存 → 次回起動時にその値を `ideal:` として渡す。

この方式の限界（Risks参照）：
- ピクセル完全な復元ではなく「近似的な復元」（次回起動時の初期幅として使われるのみ）
- ドラッグ中に高頻度で書き込みが発生しうるため、デバウンス必須

---

## Acceptance Criteria

1. サイドバー（左カラム）は 120pt〜400pt の範囲でドラッグ可変になっている（`SidebarModeView.swift` の `navigationSplitViewColumnWidth` パラメータで確認可能）。
2. サイドバー幅が約230pt未満のとき `PhotoListView` は1列表示、約230pt以上のとき自動的に2列表示になる（`LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 240))])` の実機挙動で確認）。
3. サムネイル表示サイズは最大240px程度までスケールする（`GridItem` の `maximum` パラメータ、および実機での見た目で確認）。
4. アプリを再起動すると、直前のサイドバー幅に近い値で起動する（`@AppStorage("sidebarWidth")` の読み書きをコードで確認＋実機再起動テスト）。
5. サイドバーモードでの上下矢印キーによる写真選択切替が、グリッド化後も引き続き動作する（`List` 除去に伴う回帰がないことを実機確認）。
6. 新規グリッドセルにハードコードされた色値がなく、ライト/ダーク両モードで正しく表示される（コードレビュー＋実機トグル確認）。
7. 新規グリッドセルの操作可能要素（サムネイル本体・お気に入り星）に `.accessibilityLabel` が付与されている（コード確認）。
8. ビルドが成功し、SwiftLint违反（force_unwrapping等）が新規に増えていない。

---

## Implementation Steps

### Step 1 — サイドバー幅の可変範囲を拡張＋永続化

**File:** `ShootLog/Features/Viewer/Views/SidebarModeView.swift`

- `@AppStorage("sidebarWidth") private var sidebarWidth: Double = 140` を追加。
- 12行目の `.navigationSplitViewColumnWidth(min: 120, ideal: 140, max: 200)` を `.navigationSplitViewColumnWidth(min: 120, ideal: sidebarWidth, max: 400)` に変更。
- 左カラムのコンテンツ（`PhotoListView` を包む部分）に `.background(GeometryReader { geo in Color.clear.onChange(of: geo.size.width) { newWidth in /* デバウンスして sidebarWidth へ保存 */ } })` を追加。
  - デバウンス実装：直近保存値との差が1pt未満なら無視、かつ `Task` + `Task.sleep(for: .milliseconds(300))` を用いて連続変化中は書き込みを遅延・キャンセルする（`async/await` のみ使用、`Combine`/`DispatchQueue` 禁止のプロジェクトルールに準拠）。

### Step 2 — `PhotoListView` を List から adaptive グリッドへ変更

**File:** `ShootLog/Features/Library/Views/PhotoListView.swift`

- `List(selection:)`（現行10行目）を `ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 240), spacing: 8)], spacing: 8) { ForEach(photos) { photo in PhotoGridCell(...) } } }` に置き換える。
- `PhotoListRow`（22-64行目）を `PhotoGridCell` にリネーム・改修：
  - サムネイル：アスペクト比3:2を維持しつつ、セル幅いっぱいにスケール（現行の `.frame(maxWidth: .infinity)` 相当をグリッドセル向けに調整）。
  - 選択状態のハイライト：`List` が自動提供していた選択ハイライトが失われるため、`.overlay(RoundedRectangle...).stroke(選択時に強調色)` 等で明示的に実装。セマンティックカラー使用（ハードコード禁止、プロジェクトルール準拠）。
  - お気に入り星バッジ・ファイル名ラベルは現行同様に維持。
  - 各操作可能要素（サムネイルタップ領域・お気に入り星）に `.accessibilityLabel` を付与（未付与なら追加、プロジェクトルール準拠）。
- クリックで `selection`（バインディングされた選択中Photo）を更新するタップジェスチャーを明示追加（`List` の暗黙選択動作の代替）。

### Step 3 — 矢印キーによる選択ナビゲーションの回帰防止

**File:** `ShootLog/Features/Viewer/Views/SidebarModeView.swift`（または `PhotoListView.swift`）

- `List` 除去で失われる可能性のある上下矢印キー選択を、`.onKeyPress(.upArrow)` / `.onKeyPress(.downArrow)` で明示的に `vm.selectPrevious()` / `vm.selectNext()` に接続（`MainViewModel` に既存の同名メソッドを使用、`FullscreenModeView.swift` の左右矢印実装パターンに倣う）。

### Step 4 — 動作確認

- `run` スキル、または手動でアプリを起動し、サイドバーをドラッグで120〜400ptの範囲まで広げ、約230pt付近で1列→2列に切り替わることを目視確認。
- アプリを再起動し、直前の幅に近い状態で開くことを確認。
- サイドバーモードで上下矢印キーによる選択切替を確認。
- ライト/ダークモード切替でグリッドセルの見た目に問題がないか確認。

---

## Risks and Mitigations

| リスク | 対策 |
|--------|------|
| `NavigationSplitView` は実幅を読み取るAPIがなく、`GeometryReader`経由の近似実装になる | 「次回起動時の初期値」としてのみ機能する近似的永続化である旨をAcceptance Criteria/ドキュメントに明記。ピクセル完全一致は保証しない |
| ドラッグ中の`GeometryReader`変化検知で`@AppStorage`への書き込みが頻発しUI/ディスクI/Oが増える | デバウンス（300ms程度）＋差分1pt未満は無視するガードを実装 |
| `List`除去により暗黙的に得ていた選択ハイライト・キーボードナビ・アクセシビリティが失われる | Step2/3で明示的に選択ハイライト・矢印キー・`.accessibilityLabel`を再実装 |
| `LibraryView.swift`（未使用の110-160pxグリッド）と今回追加する110-240pxグリッドで定数が重複・混乱を招く可能性 | 今回はスコープ外として触れない。将来`LibraryView`統合時に定数を一本化するフォローアップとして記録 |
| 2列化の閾値（約230pt）はadaptive gridの自動計算に一任するため、正確な閾値をコード上でハードコードしていない | 意図的な設計（自動フィット）であり、閾値を厳密指定したい場合は`GridItem`の`minimum`値を調整すれば挙動が変わる旨をコメントで明記 |

---

## Verification Steps

1. `xcodebuild build`（または Xcode上でビルド）でコンパイルエラーがないことを確認。
2. `run` スキルでアプリを起動し、Acceptance Criteria 1〜7を実機で目視・操作確認。
3. SwiftLintを実行し、新規の`force_unwrapping`等の違反がないことを確認。
4. ライト/ダークモード両方で新規グリッドセルの見た目を確認（プロジェクトルール準拠）。

---

## Follow-ups（今回スコープ外）

- `LibraryView.swift` の未使用グリッドコード（110-160px）と今回実装するグリッド（110-240px）の重複整理。Phase5でのSidebarModeView統合時にまとめて解消する。
- サムネイルサイズ・列数をユーザーが手動でも選べるようにする設定UI（今回は自動切替のみ、要望があれば別途）。
