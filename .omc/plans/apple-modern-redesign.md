# ShootLog UIモダン化計画（Apple HIG準拠）

**ステータス: pending approval**（このプランはまだ承認されていない。実装開始には明示的な承認が必要）

## 決定事項サマリ（インタビューで確定）

| 項目 | 決定 |
|------|------|
| 範囲 | アプリ全体（ツールバー・写真一覧・EXIFパネル・ビューアHUD・エディタ・分析画面） |
| Liquid Glass方針 | Glassを主軸に。macOS 26は`.glassEffect`、14〜25は`.regularMaterial`/`.ultraThinMaterial`フォールバック |
| デザイントークン | 新規`DesignSystem.swift`で色・角丸・タイポグラフィ・シャドウを一元化 |
| ネイティブコントロール | 自作ボタン（RoundedRectangle+opacity手動選択状態）はSwiftUI標準スタイルに置換 |
| 参考モックアップ | `Docs/UI_モックアップ.html`をGlass/Material/ダークHUDを反映した新デザインで作り直す |

---

## 現状分析（実測済み・file:line根拠）

### 既存のGlass基盤（再利用する）
- `Shared/UI/ToastView.swift:18-56` に`glassOrMaterial(cornerRadius:)` / `glassOrMaterialCapsule()` / `glassOrMaterialCircle()` が定義済み。`#available(macOS 26, *)`で`.glassEffect(in:)`、フォールバックで`.regularMaterial`/`.ultraThinMaterial`。
- 採用済み箇所: `EmptyStateView.swift:61`, `LibraryView.swift:86`, `FullscreenModeView.swift:49,77,125`, `SlideshowModeView.swift:26,104,117`, `EditorToolbarView.swift:23`。
- 未採用・要修正箇所: `SidebarModeView.swift:17`（`.background(.regularMaterial)`直書き、ヘルパー未使用）、`EXIFPanelView.swift`（背景なし）、`ContentView.swift`のツールバーモードボタン（74-80、手動RoundedRectangle）。

### ハードコード色（置換対象、file:line）
- `FullscreenModeView.swift:75,92,106,122` — `.white`/`.white.opacity(0.7)`
- `SlideshowModeView.swift:47,65,77,87,96` — `.white`系
- `CropOverlayView.swift:27,29,35,53,118,120,159,162` — `.black.opacity`/`.white`/shadow
- `SidebarModeView.swift:31` — `.background(.black)`（意図的、写真ビューア背景として維持）
- `ToastView.swift:40-41` — `.foregroundStyle(.white)` / `Color.black.opacity(0.75)`
- `PageDotsView.swift:16` — `Color.white`系（黒背景前提、維持可）
- `EXIFPanelView.swift:91` — `Color.blue.opacity(0.15)`バッジ背景
- `LibraryView.swift:125` — shadow
- `AnalysisView.swift:24` — `Color(.windowBackgroundColor)`（NSColorブリッジ、セマンティック化対象）

**方針**: 黒背景の写真ビューア/フルスクリーン/スライドショー（CLAUDE.md規定によりこれらは`.black`固定が正）はそのまま維持。ただしその上に乗るテキスト/アイコン色はDesignSystemの`.onDarkCanvas`トークンとして一元化し、散在するリテラルを1箇所の定義に集約する。EXIFPanel・Sidebar・Analysisなどライト/ダーク両対応が必要な箇所は完全にセマンティックカラー化する。

### 自作ボタン・非ネイティブコントロール（置換対象）
- `ContentView.swift:74-80` モード切替（手動RoundedRectangle選択ハイライト）→ ネイティブセグメント風に。
- `FullscreenModeView.swift` NavButton/FavoriteButton/CloseButton (66-111)
- `SlideshowModeView.swift` 再生コントロール (61-90)
- `EditorToolbarView.swift` EditorButton (28-47)
- `CropOverlayView.swift` cropActionStyle (155-165)

### タイポグラフィの二重系統
- Dynamic Type系: EmptyStateView, EXIFPanelView, AnalysisView, LibraryViewの一部で`.title2`/`.caption`等使用済み。
- 固定px系: `FullscreenModeView` (46,74,91,105,121), `SlideshowModeView` (23,46,76,99,114), `EditorToolbarView:37`, `AnalysisView` (73,94,104,153,169,178), `LibraryView:123`。

### 角丸値の散在
2/3/4/5/6/8/12/20ptがファイルごとに異なる値でハードコード。トークン化対象。

---

## 実装ステップ

### Phase 0: モックアップ再設計
1. `Docs/UI_モックアップ.html`を新デザイン方針で作り直す。
   - Glass/Materialの視覚表現（半透明・ぼかし）を反映
   - ライト/ダーク両対応のカラーパレット提示
   - 既存の黒背景ビューア/フルスクリーン/スライドショーのHUDデザインを整理して明記
   - アクセントカラーは`Color.accentColor`（システムアクセント）に統一し、独自hex（`#3478f6`等）は廃止する方針を明記
   - お気に入り★の色を`.yellow`（システム）か専用アクセントかを1箇所で決定し明記（現状mockup `#c8820a` vs 実装`.yellow`の乖離を解消）

### Phase 1: DesignSystem.swift 新規作成
`ShootLog/Shared/UI/DesignSystem.swift`（新規ファイル、英語識別子・日本語コメント）
- `enum CornerRadius`: `.small(4) .medium(8) .large(12) .pill(20)`等、実測値を集約し値を統一（現状バラバラな2/3/4/5/6/8/12/20ptを整理・削減）
- `enum Elevation`: シャドウ定義（現状2箇所のみ→統一トークン化）
- `enum HUDTypography` / 既存Dynamic Type併用方針: 黒背景HUD用の固定サイズフォントをここに集約（完全排除はせず、意図的な差異として明示コメントを付与）
- `extension Color`: `.onDarkCanvas` `.onDarkCanvasSecondary`等、黒背景上のテキスト/アイコン色をセマンティックに命名
- 既存`ToastView.swift`のglassヘルパー3種をこのファイルに移設（責務の所在を明確化）し、`ToastView.swift`からはimportのみで参照

### Phase 2: Glass/Material適用の全面展開
- `SidebarModeView.swift:17` を`.background(.regularMaterial)`直書きから`glassOrMaterial`ヘルパーに置換
- `EXIFPanelView.swift` に背景マテリアルを追加（現状背景なし）
- `ContentView.swift`ツールバー領域にマテリアル適用検討

### Phase 3: ハードコード色の解消
- 黒背景HUD（Fullscreen/Slideshow/CropOverlay/ToastView/PageDots）: `Color.onDarkCanvas`系トークンに置換
- ライト/ダーク対応必須箇所（EXIFPanelView, AnalysisView, LibraryView shadow, EditorToolbarView）: セマンティックカラー化
- `AnalysisView.swift:24` の`Color(.windowBackgroundColor)`を`glassOrMaterial`背景に置換検討

### Phase 4: ネイティブコントロールへの置換
- `ContentView.swift`ツールバーモードボタン: 手動ハイライトを廃し、選択状態を`ButtonStyle`カスタム実装（ネイティブの見た目・挙動に寄せる。単純な`Picker(.segmented)`は複数アイコンボタン+ツールチップ要件と相性を見て判断）
- `FullscreenModeView`/`SlideshowModeView`のNav/Favorite/Close/再生ボタン: `.buttonStyle(.plain)`+手動装飾から、`ButtonStyle`準拠のカスタムスタイル（DesignSystem管理下）に統一。フォーカスリング・ホバー状態などネイティブが提供する挙動を活かす
- `EditorToolbarView`のEditorButton、`CropOverlayView`のcropActionStyle: 同様に統一ButtonStyleへ集約

### Phase 5: タイポグラフィ統一
- 固定px指定を`DesignSystem.HUDTypography`トークン経由に変更（値自体は据え置き可、ただし1箇所管理に変更）
- Dynamic Type系は現状維持、必要に応じて`.dynamicTypeSize(...clamped)`検討（黒背景HUDでの極端な拡大崩れ防止）

### Phase 6: 各Viewへの適用（ビルド確認しながら段階的に）
実装順序: DesignSystem → Sidebar/List/EXIFPanel → Fullscreen/Slideshow → Editor → Analysis → ContentView（ツールバー）
各ステップ後にビルドし、ライト/ダーク両モードで目視確認する。

### Phase 7: アクセシビリティ・最終確認
- 新規/変更ボタンに`.accessibilityLabel`付与漏れがないか全体チェック
- ライト/ダーク両モードでのコントラスト確認（特に黒背景HUD上のセマンティックカラー化した要素）

---

## 受け入れ基準（Acceptance Criteria）

- [ ] `ShootLog/Shared/UI/DesignSystem.swift`が存在し、角丸・シャドウ・黒背景用カラーのトークンを提供する
- [ ] `Color.white` / `Color.black.opacity` の直接リテラルが黒背景ビューア系（Fullscreen/Slideshow/CropOverlay/PageDots/Toast）以外に存在しない（`grep -rn "Color\.white\|\.white\.opacity\|Color\.black" ShootLog/Features/Viewer ShootLog/Features/Editor ShootLog/Features/Library ShootLog/Features/Analysis`で確認）
- [ ] `SidebarModeView.swift:17`が`glassOrMaterial`ヘルパー経由になっている
- [ ] `EXIFPanelView.swift`に背景マテリアルが適用されている
- [ ] `ContentView.swift`のツールバーモードボタンが統一ButtonStyle経由になっている（手動RoundedRectangle選択ハイライトが個別実装として残っていない）
- [ ] `AnalysisView.swift:24`の`Color(.windowBackgroundColor)`がセマンティック/マテリアル背景に置換されている
- [ ] `Docs/UI_モックアップ.html`が新デザイン方針（Glass/Material・アクセントカラー統一・★色統一）で更新されている
- [ ] 全変更後、Xcodeビルドが成功する（`xcodebuild -scheme ShootLog build`相当）
- [ ] ライトモード・ダークモード両方で主要画面（Sidebar/Fullscreen/Slideshow/Analysis）を目視確認し、視認性に問題がない
- [ ] 新規/変更した操作可能要素すべてに`.accessibilityLabel`が付与されている
- [ ] `try!`・`ObservableObject`・`Combine`・`DispatchQueue`が新規コードに含まれない（CLAUDE.md規約）
- [ ] 識別子は英語、コメントは日本語（CLAUDE.md規約）

---

## リスクと軽減策

| リスク | 軽減策 |
|--------|--------|
| macOS 26未満の環境でGlass外観を確認できず、フォールバック品質を見落とす | 開発機がmacOS 26未満の場合、`#available`分岐の両方をコードレビューで目視確認。可能ならOSバージョンを跨いだ簡易テストを検討 |
| ボタンをネイティブStyleに寄せることで既存のHUD上の視認性（黒背景+白系装飾）が崩れる | DesignSystemの`.onDarkCanvas`トークンを介して色を明示的に維持し、Style変更と色変更を分離してコミットする |
| 角丸/シャドウ値を統一する際、既存の見た目が変わり规約書のUIモックアップと乖離する | Phase 0でモックアップを先に更新し、それを実装のリファレンスとして各Phaseで参照する |
| 変更範囲が全画面に及ぶため、途中でビルドが壊れた状態が長引く | Phase順（DesignSystem→個別View）で段階コミット。CLAUDE.md規約通り「各Phaseは単体で動作確認できる状態にしてからコミットする」を厳守 |
| EXIFPanelViewへの背景追加が既存のColorモードバッジ（青背景バッジ）と重なり視認性が悪化する | 背景マテリアル追加後にバッジのコントラストを目視確認し、必要ならバッジ背景の不透明度を調整 |

---

## 検証手順

1. 各Phase完了後: `xcodebuild -project ShootLog.xcodeproj -scheme ShootLog build`（またはXcodeでビルド）が成功することを確認
2. `grep -rn "Color\.white\|Color\.black\b" ShootLog/` で意図しないハードコード残存がないか確認
3. アプリを起動し、システム設定でライト/ダークを切り替えながら以下を目視確認:
   - サイドバーモード（写真一覧・EXIFパネル・中央ビューア）
   - フルスクリーンモード（前後ナビ・★・閉じる）
   - スライドショーモード（速度切替・再生コントロール）
   - エディタ（トリミングオーバーレイ・ツールバー）
   - 分析画面（グラフ・フィルタ）
4. `.accessibilityLabel`の付与漏れをVoiceOver ONで簡易確認（主要操作要素にフォーカスが当たり読み上げされるか）
5. `Docs/UI_モックアップ.html`をブラウザで開き、実装後の見た目と整合しているか比較

---

## 変更履歴（このプランに対する）

- 初版作成。インタビューで確定した5つの決定事項（範囲・Glass方針・トークン化・ネイティブコントロール・モックアップ扱い）を反映。
