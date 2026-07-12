# タイトルバー/サイドバー/ビューア デザイン是正プラン

**ステータス: pending approval**（未承認。実装開始には明示的な承認が必要）

前提: `apple-modern-redesign.md`（Glass基盤導入）は大部分が実装済み（`DesignSystem.swift`存在、`EXIFPanelView`/`EmptyStateView`等がglassOrMaterial採用済み）。本プランはその上で残った「タイトルバー背景色の違和感」「ボタンが背景と被る」「余白不整合」を是正する第2ラウンド。

---

## 根本原因（コード実測・file:line根拠）

コード内に `.windowStyle` / `.toolbarBackground` / `NSWindow` 直接操作は**一切存在しない**（grep確認済み）。つまりタイトルバー自体はmacOS標準のunified toolbar材質で、システムが自動的にライト/ダーク適応している。「背景色がおかしい」の正体はタイトルバー自体ではなく、**その上に乗るツールバーボタンの装飾がシステム材質と衝突している**こと。

### 1. モード切替ボタンが単色塗り・非ネイティブ（`ContentView.swift:117-128`）
```swift
private struct ModeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            ...
    }
}
```
- 選択時のみ`accentColor.opacity(0.2)`のベタ塗り矩形が出現。ブラー・境界線なしのフラットカラーが、システムのvibrancyツールバー背景の上に唐突に乗るため「タイトルバー背景がおかしい」に見える。
- 非選択時は`Color.clear`＝装飾ゼロ。同じグループ内で選択/非選択のボタンの見た目差が大きすぎ、Apple純正のセグメント風トグルに見えない。
- `padding(4)`のみでヒットターゲット固定サイズなし。アイコン形状によってボタン幅がバラつき、横並びが不揃いになる（モックアップ`Docs/UI_モックアップ.html:128-134`の`.tbtn`は`width:26px height:22px`で固定）。

### 2. ツールバー内ボタン群で装飾方針が不統一（`ContentView.swift:70-110`）
- `navigation`配置（モード切替）だけ独自`ModeButtonStyle`。`primaryAction`配置（フォルダ/分析/外部アプリ）は無装飾のデフォルトツールバーボタン。同一ツールバー内で「背景色つきボタン」と「素のアイコン」が混在し、統一感がない＝「Appleのデザインらしくない」の直接原因。

### 3. EXIFパネルが列の縁とぶつかる角丸グラス（`EXIFPanelView.swift:44-45`）
```swift
.frame(width: 156)
.glassOrMaterial(cornerRadius: CornerRadius.large)
```
- `NavigationSplitView`の`detail`列はSwiftUIが既にシステム標準の背景材質を与えている。その列いっぱいに、外側パディングなしで`cornerRadius: .large(12)`の角丸グラスを重ねているため、列の上下左右の直角境界と角丸グラスの丸みが衝突し、四隅に地の背景が三角に覗く。これが右カラムの「ボタン（＝パネル）が背景と被る」の主因。
- 同種の懸念は`apple-modern-redesign.md:125`のリスク欄で「EXIFPanelViewへの背景追加が既存のバッジと重なり視認性が悪化する」として事前に指摘されていたが、角丸と列境界の衝突は未検証のまま残っていた。

### 4. 左カラム（`PhotoListView.swift`）は無装飾のまま
- `SidebarModeView.swift:15-16`で`PhotoListView`をそのまま列に渡しており、背景はシステムのリスト材質任せ。右カラム（EXIFパネル）だけ角丸グラスが乗っているため、左右で質感が非対称＝サイドバー全体のデザインがちぐはぐに見える。

### 5. 余白の粒度が箇所ごとにバラバラ
- `PhotoListView.swift:24` グリッド外周 `padding(8)`
- `EXIFPanelView.swift:42` パネル内 `padding(10)`
- `EditorToolbarView.swift:21-24` `padding(.horizontal, 8).padding(.vertical, 6)` の外側にさらに `padding(10)`
- `EmptyStateView.swift:71` 全体 `padding()`（デフォルト20相当）
いずれも`DesignSystem.swift`に余白トークンが存在せず、値が各Viewにハードコードされたまま。角丸(`CornerRadius`)・シャドウ(`Elevation`)はトークン化済みだが余白だけ未整備＝ `apple-modern-redesign.md`のスコープから漏れていた箇所。

---

## 修正方針

### A. ツールバーボタンをApple純正の見た目に統一
- `DesignSystem.swift`に`enum Spacing`（4/8/12/16等、既存の実測値を集約）を追加し、余白トークンを一元化。
- `DesignSystem.swift`に`ToolbarButtonStyle`を新設: 固定ヒットターゲット（幅28×高さ22目安、モックアップ準拠）、非選択時も薄いボーダー（`Color.primary.opacity(0.08)`程度、新トークン`Color.controlBorder`として追加）、選択時は`Color.accentColor.opacity(0.15)`背景＋`RoundedRectangle(cornerRadius: .small)`。ボーダーを常時表示することで選択/非選択の差を「色」ではなく「塗りの有無」に統一し、フラット矩形が唐突に浮く印象を消す。
- `ContentView.swift`のモード切替ボタン（117-128）を`ToolbarButtonStyle`に置換。`primaryAction`側（フォルダ/分析/外部アプリ、83-109）にも同スタイルを適用し、ツールバー内の装飾方針を統一する。

### B. EXIFパネルの角丸グラスを列に馴染ませる
- `EXIFPanelView.swift`の`glassOrMaterial(cornerRadius: .large)`を列全体に対して使うのをやめ、列自体は`.background(.regularMaterial)`のフラット（角丸なし）に変更するか、角丸グラスを使うなら列幅いっぱいではなく上下左右に`padding(6)`程度を入れてカード状に浮かせる。後者はモックアップ（`Docs/UI_モックアップ.html:179`の`.exif-panel`はボーダーのみで角丸なし＝カラム全体がフラット材質）と整合しないため、**列全体フラット化を推奨**。
- 左カラム（`PhotoListView`）にも同じ`.background(.regularMaterial)`級の材質を明示適用し、右カラムと質感を揃える（現状はシステム任せで暗黙的なため、明示化して左右の一貫性を保証する）。

### C. 中央ビューア（`EditablePhotoView`/`EditorToolbarView`）の余白見直し
- `EditorToolbarView.swift:21-24`の二重padding（内側8/6＋外側10）を`Spacing`トークンに置換し、値の意図（内側=ボタン間余白、外側=写真端からの距離）をコメントで明記。
- フルスクリーン/スライドショーのHUD（`FullscreenModeView.swift`, `SlideshowModeView.swift`）は既にglassOrMaterialCircle/Capsule採用済みで完成度が高いため変更不要（`apple-modern-redesign.md` Phase 4で対応済み）。

### D. `Docs/UI_モックアップ.html`のツールバー部分を更新
- `.tbtn`のボーダー常時表示ルールを、実装後のトグルボタン挙動（非選択時もうっすら枠あり）に合わせて調整し、実装との乖離を無くす。

---

## 実装ステップ

1. `ShootLog/Shared/UI/DesignSystem.swift`
   - `enum Spacing`追加（余白値集約）
   - `Color.controlBorder`（新規セマンティックカラートークン）追加
   - `ToolbarButtonStyle`（`ButtonStyle`準拠、固定サイズ＋常時ボーダー＋選択状態）追加
2. `ShootLog/Features/Library/Views/ContentView.swift`
   - 既存`ModeButtonStyle`を削除し`ToolbarButtonStyle`に置換
   - `primaryAction`グループのボタンにも`ToolbarButtonStyle`適用
3. `ShootLog/Features/Viewer/Views/EXIFPanelView.swift`
   - 列全体角丸グラスをフラット材質背景に変更（角丸を列端まで持たせない）
4. `ShootLog/Features/Viewer/Views/SidebarModeView.swift`
   - `PhotoListView`列に明示的な材質背景を追加し左右の質感を統一
5. `ShootLog/Features/Editor/Views/EditorToolbarView.swift`
   - padding値を新設`Spacing`トークン経由に置換
6. `Docs/UI_モックアップ.html`
   - `.tbtn`のボーダー表現を更新し実装と整合
7. 各ステップ後にビルド確認（`xcodebuild -project ShootLog.xcodeproj -scheme ShootLog build`）、ライト/ダーク両方で目視確認してからコミット（CLAUDE.md規約通り1 Phase = 1コミット）

---

## 受け入れ基準

- [ ] `ContentView.swift`のモード切替ボタン・primaryActionボタンが同一`ToolbarButtonStyle`を使用し、選択/非選択とも常時ボーダーを持つ（フラット単色矩形が突発的に浮かない）
- [ ] `ToolbarButtonStyle`適用後、モード切替ボタンのヒットターゲットが揃った固定サイズになっている（目視でガタつきなし）
- [ ] `EXIFPanelView.swift`の背景が`NavigationSplitView`列の直角境界と衝突しない（角丸が列端に触れていない、または角丸自体を廃してフラット化）
- [ ] 左カラム（`PhotoListView`）と右カラム（`EXIFPanelView`）の材質・境界表現が視覚的に対になっている
- [ ] `EditorToolbarView`の余白が新設`Spacing`トークン経由になっている（マジックナンバー`8`/`6`/`10`の直書きが残っていない）
- [ ] `DesignSystem.swift`に`Spacing`・`Color.controlBorder`・`ToolbarButtonStyle`が追加されている
- [ ] ライトモード・ダークモード両方でツールバー/サイドバー/EXIFパネルを目視確認し、タイトルバーとの境界に違和感がない
- [ ] 新規/変更ボタンすべてに`.accessibilityLabel`が付与されている
- [ ] `Docs/UI_モックアップ.html`が実装後のツールバーボタン表現と整合している
- [ ] 識別子は英語、コメントは日本語（CLAUDE.md規約）。`try!`・`ObservableObject`・`Combine`・`DispatchQueue`不使用

---

## リスクと軽減策

| リスク | 軽減策 |
|--------|--------|
| 常時ボーダー化で非選択ボタンが「常にアクティブっぽい」誤読を招く | ボーダー色を`Color.primary.opacity(0.08)`程度の極薄に抑え、選択状態は背景色で明確に差別化。実機でライト/ダーク双方コントラスト確認 |
| EXIFPanelViewのフラット化で既存のカラーモードバッジ・お気に入り行のコントラストが変わる | フラット化後にバッジ背景（`EXIFPanelView.swift:92`の`Color.blue.opacity(0.15)`）のコントラストを目視再確認 |
| `primaryAction`グループにもボーダー適用すると、macOS標準ツールバーの見た目から逸脱しすぎる可能性 | 実装後に純正Appアプリ（写真.app/Finder）のツールバーと横並び比較し、逸脱が大きければボーダー適用対象を「モード切替グループのみ」に限定する代替案に切り替える |
| 変更範囲が`ContentView`/`EXIFPanelView`/`SidebarModeView`/`EditorToolbarView`と複数ファイルに及ぶ | ステップ順（DesignSystem→ContentView→EXIFPanel→Sidebar→EditorToolbar→モックアップ）で1ファイルごとに段階コミット |

---

## 検証手順

1. 各ステップ後: `xcodebuild -project ShootLog.xcodeproj -scheme ShootLog build`成功確認
2. アプリ起動、システム設定でライト/ダーク切替しながら以下を目視:
   - サイドバーモードのツールバー（モード切替＋フォルダ/分析/外部アプリボタン）
   - 左カラム（写真一覧）と右カラム（EXIFパネル）の質感対比
   - 中央ビューアの編集ツールバー余白
3. `grep -rn "padding(4)\|padding(6)\|padding(8)\|padding(10)" ShootLog/Features/Library/Views/ContentView.swift ShootLog/Features/Editor/Views/EditorToolbarView.swift` でSpacingトークン移行漏れがないか確認
4. VoiceOver ONで新規/変更ボタンのアクセシビリティラベル読み上げ確認
5. `Docs/UI_モックアップ.html`をブラウザで開き実装後の見た目と比較

---

## 未確定事項（要ユーザー判断・実装前に確認推奨）

- primaryActionボタン（フォルダ/分析/外部アプリ）にもボーダー装飾を適用するか、モード切替グループのみに限定するか（上記リスク欄参照）
- EXIFPanelViewを「列端まで角丸なしフラット」にするか「余白を入れてカード状に浮かせる」か（本プランはモックアップ整合を理由に前者を推奨）
