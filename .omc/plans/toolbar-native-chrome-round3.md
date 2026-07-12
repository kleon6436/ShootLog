# タイトルバー/ツールバー/サイドバー デザイン是正プラン（第3ラウンド）

**ステータス: pending approval**（未承認。実装開始には明示的な承認が必要）

## 前提（重要）

先行プラン2件は**コード上は実装済み**であることをファイル実測で確認した。
- `apple-modern-redesign.md`: `DesignSystem.swift`新設・Glass適用・ハードコード色解消 → 実装済み
- `titlebar-sidebar-toolbar-polish.md`: `Spacing`/`Color.controlBorder`/`ToolbarButtonStyle`新設、`ContentView.swift`両ツールバーグループへの適用、`EXIFPanelView`/`SidebarModeView`のフラット材質化、`EditorToolbarView`のSpacingトークン化 → **すべて実装済み**（`DesignSystem.swift:33-39,113,138-146`、`ContentView.swift:79,88,97`、`EXIFPanelView.swift:44-52`、`SidebarModeView.swift:17-34`、`EditorToolbarView.swift:22,26`で確認）

にもかかわらず、今回のスクリーンショット（2026-07-11撮影）では同じ症状（タイトルバー背景の違和感／ボタンが背景と被る）が再現している。つまり**前プランの是正方針そのものが不十分**だった。本プランはその原因を再診断し、次の一手を出す。

---

## 再診断（コード実測＋スクリーンショット照合）

### 1. 「常時薄ボーダー」方針が実機では見えていない（`DesignSystem.swift:113,122-131`）
```swift
static let controlBorder = Color.primary.opacity(0.08)
```
前プランのリスク欄（`titlebar-sidebar-toolbar-polish.md:111`）で「常時ボーダー化で非選択ボタンが誤読を招く」リスクを認識しつつ、実機コントラスト確認は未実施のまま承認・実装されていた。ダークモードのツールバー背景（システムvibrancy、黒に近い）に対し`Color.primary.opacity(0.08)`は白地では薄灰程度だが黒地ではほぼ不可視。スクリーンショットのツールバー右側（フォルダ・分析・共有アイコン）にボーダーが視認できないのはこれが原因。**「ボタンが背景と被る」の直接的な再現**。

### 2. 全ボタンに同一の「箱型」装飾を適用したこと自体がApple流ではない（`ContentView.swift:79,88,97`）
`navigation`配置（モード切替＝本来セグメント的にグルーピングされるべき操作）と`primaryAction`配置（フォルダ／分析／共有＝独立したプレーンアイコン操作）の両方に同一の`ToolbarButtonStyle`（固定枠28×22＋常時ボーダー）を適用している。だが実際のFinder/写真.app/プレビュー等のツールバーでは、**プレーンな単発アクションアイコンは枠を持たず、ホバー時のみシステムが自動でハイライトを出す**。すべてのボタンに恒久的な箱を与えたこと自体が「Appleのデザインらしくない」の根本原因であり、前プランの是正方針が逆効果だった。

### 3. モード切替ボタンの選択状態がアクセントカラー薄塗りのみ（`ContentView.swift:79`、`DesignSystem.swift:122-131`）
選択時`Color.accentColor.opacity(0.15)`、非選択時ほぼ不可視ボーダー。スクリーンショット左端の選択中モードアイコンだけ辛うじて青枠が見えるが、グループとして「セグメントコントロールである」という視覚的まとまり（外周の共有カプセル背景）が無いため、3つの独立ボタンが並んでいるようにしか見えない。

### 4. 左サイドバー：選択中サムネイルのハイライトが弱い（`PhotoListView.swift:44-49`）
```swift
RoundedRectangle(cornerRadius: CornerRadius.small)
    .strokeBorder(Color.accentColor, lineWidth: 2)
```
角丸2ptストロークのみ。Finder/写真.appのグリッド選択は「セル全体を淡いアクセント色で塗り＋枠」が標準で、ストロークのみだと選択状態が弱く、暗いサムネイル画像の上では特に視認しづらい。

### 5. 余白：グリッド外周とセル間隔が同値で階層がない（`PhotoListView.swift:10,14,24`）
`columns`の`spacing: 8`・`LazyVGrid`の`spacing: 8`・外周`padding(8)`が全て`Spacing.medium`相当の同一値。Apple純正グリッド（写真.appのサムネイルグリッド等）は「セル間隔 < コンテナ外周余白」で階層を作るのが通例。全部同値だとサムネイルが端に詰まって見える＝「余白が正しく使われていない」の一因。

### 6. タイトルバー行とツールバー行の二段表示（要実機確認・確度中）
`ContentView.swift`に`.navigationTitle`は存在せず（`grep`確認済み）、ウィンドウタイトルはInfo.plistの`CFBundleDisplayName`（`ShootLog`）がデフォルト表示される。`.windowToolbarStyle`の指定も無いため、SwiftUIのデフォルト（`.automatic`）に委ねられている。スクリーンショットでは信号機列とツールバー行が視覚的に2段に見えるが、これがOS標準の正常表示か、`.automatic`が非推奨の旧来スタイルにフォールバックしているのかはコード上100%断定できない。**実装時に`.windowToolbarStyle(.unifiedCompact(showsTitle: false))`を試し、Finder/写真.appと横並び比較して判断する**（未確定事項として明記）。

---

## 修正方針

### A. ツールバーボタンを「役割別」の見た目に分離する
- `DesignSystem.swift`の`ToolbarButtonStyle`/`toolbarButtonAppearance`を**グループ選択用**として残しつつ、`primaryAction`（フォルダ・分析・共有）には適用しない。プレーンな`Button`＋アイコンのみに戻し、システム標準のホバー/押下ハイライトに委ねる。
- モード切替（`navigation`配置、`ContentView.swift:72-81`）は個々のボタンに枠を付けるのではなく、**3ボタンをまとめて1つの角丸カプセル/グループ背景**（`.background(.quaternary, in: RoundedRectangle(cornerRadius: CornerRadius.medium))`程度）で囲み、選択中のボタンだけ内側にアクセント塗り＋前景色反転を適用する。セグメントコントロールらしい「グループの一体感」を出す。

### B. `Color.controlBorder`の不透明度を実機検証の上で調整
- ライト/ダーク双方でコントラスト実測し、暗いツールバー背景でも視認できる値（例: `Color.primary.opacity(0.12)`前後、要実機調整）に変更するか、**外周ボーダーを廃してBの方針（グループ背景）に一本化**する。前プランの「ボーダーで差別化」というアイデア自体を見直すため、Aの方針が確定すればボーダー方針は不要になる可能性が高い。

### C. サムネイル選択ハイライトを面で表現する（`PhotoListView.swift:44-49`）
- ストロームのみから、`RoundedRectangle(fill: Color.accentColor.opacity(0.15))`をサムネイル背後に敷き＋外周に既存の2ptストロークを残す形に変更。セル全体のタップ領域（`PhotoGridCell`）にも軽い背景を敷き、行全体が選択されて見えるようにする。

### D. 余白に階層を持たせる（`PhotoListView.swift:10,14,24`、`DesignSystem.swift`のSpacing）
- グリッド外周`padding`を`Spacing.large(10)`または`xLarge(12)`に、セル間`spacing`は現行`Spacing.medium(8)`のまま据え置き、「外周 > セル間隔」の階層を作る。
- 同様に`EXIFPanelView.swift:42`の内側`padding(Spacing.large)`と列外周の関係、`SidebarModeView`の列間ボーダー余白も含めて全体の余白階層を1つの表として`DesignSystem.swift`にコメントで明記する。

### E. タイトルバー二段表示の検証（未確定・実装時に判断）
- `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`を`ShootLogApp.swift`の`WindowGroup`に試験適用し、Finder/写真.appと比較。改善すれば採用、変化なければ「OS標準の正常な二段表示」と結論付けドキュメント化する。

---

## 実装ステップ

1. `ShootLog/Shared/UI/DesignSystem.swift`
   - `ToolbarButtonStyle`をグループ選択専用に位置づけ直す（コメント更新）。プレーンアクション用に装飾なしの素の`Button`を許容する方針をコメントで明記
   - `Color.controlBorder`の不透明度を実機検証の上で調整（または方針Bで代替し撤去）
   - 余白階層（外周>セル間隔）をコメント付きで整理
2. `ShootLog/Features/Library/Views/ContentView.swift`
   - `navigation`配置（72-81行目）: 3ボタンを1つの`HStack`＋グループ背景でラップし、選択状態を「グループ内塗り分け」で表現
   - `primaryAction`配置（82-116行目）: `.buttonStyle(ToolbarButtonStyle())`を除去し、素の`Button`に戻す（`folder.badge.plus`・`chart.bar`・共有`Menu`のいずれも）
3. `ShootLog/Features/Library/Views/PhotoListView.swift`
   - `PhotoGridCell`（31-93行目）の選択ハイライトをストロームのみから面塗り+ストロークに変更
   - グリッド外周`padding`（24行目）をSpacingトークンの大きい方に変更し、セル間隔と差をつける
4. `ShootLog/App/ShootLogApp.swift`
   - `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`を試験適用し、実機比較の上で採用可否を決定
5. `Docs/UI_モックアップ.html`
   - モード切替のグループ化された見た目、プレーンアクションボタンの無装飾化、サムネイル選択の面塗りを反映して更新
6. 各ステップ後にビルド確認（`xcodebuild -project ShootLog.xcodeproj -scheme ShootLog build`）、ライト/ダーク両方で目視確認してからコミット（CLAUDE.md規約通り1ファイル/1論点=1コミット）

---

## 受け入れ基準

- [ ] `ContentView.swift`の`primaryAction`ボタン（フォルダ・分析・共有）が装飾なしの素のボタンになっており、システム標準のホバー/押下ハイライトのみで表現されている
- [ ] `ContentView.swift`のモード切替3ボタンが1つの共有グループ背景でまとまり、選択中のボタンのみ塗り分けで識別できる（個別ボタンごとの独立した箱には見えない）
- [ ] ダークモードのツールバー上で、モード切替グループの境界・選択状態が肉眼で明確に視認できる（ライト/ダーク双方でスクリーンショット比較し、視認性を確認する）
- [ ] `PhotoListView.swift`の選択中サムネイルがストロームのみでなく面塗りでも識別できる
- [ ] `PhotoListView.swift`のグリッド外周余白がセル間隔より広い（階層がある）
- [ ] `.windowToolbarStyle`変更を試験し、採用/非採用いずれかの結論と根拠がドキュメント（本プランの変更履歴）に残っている
- [ ] `Docs/UI_モックアップ.html`が上記変更後の見た目と整合している
- [ ] 新規/変更ボタンすべてに`.accessibilityLabel`が付与されている
- [ ] ライトモード・ダークモード双方で目視確認し、いずれの複雑度合いでも「ボタンが背景と被る」状態が解消されている
- [ ] 識別子は英語、コメントは日本語（CLAUDE.md規約）。`try!`・`ObservableObject`・`Combine`・`DispatchQueue`不使用

---

## リスクと軽減策

| リスク | 軽減策 |
|--------|--------|
| `primaryAction`ボタンの装飾を外すことで、逆に「ツールバーの中で何が押せるか分かりにくい」に戻る可能性 | システム標準ホバー/押下ハイライトは通常十分な発見可能性を持つため、実装後にVoiceOver/マウスホバーで実機確認。不足していればカーソルオンリーの`.help()`ツールチップ強化で補う |
| モード切替のグループ背景化がセグメントコントロールの標準ネイティブ挙動（キーボードフォーカスリング等）と乖離する | 可能なら`Picker(selection:) { }.pickerStyle(.segmented)`への置換も選択肢として実装時に比較検討し、カスタムButtonStyleより優先する |
| `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`がタイトル非表示によりウィンドウの識別性を下げる（複数ウィンドウ運用時に困る） | 単一ウィンドウ運用が前提のアプリのため影響小と判断。念のため`showsTitle: true`版も比較して選定 |
| 前々回・前回のプランと同様、「コード上は直した」が実機で見え方が変わらない再発 | 各受け入れ基準に「肉眼で視認できる」「ライト/ダーク双方でスクリーンショット比較」を明記し、コードの存在確認だけでなく実機目視確認を必須ステップ化 |

---

## 検証手順

1. 各ステップ後: `xcodebuild -project ShootLog.xcodeproj -scheme ShootLog build`成功確認
2. アプリを実際に起動し、システム設定でライト/ダークを切り替えながら以下をスクリーンショットで比較:
   - ツールバー（モード切替グループ＋フォルダ/分析/共有）
   - 左サイドバーの選択中サムネイル
   - グリッド外周とセル間隔の余白差
   - タイトルバー二段表示の有無（変更前後比較）
3. 変更後のスクリーンショットを本プラン起票時の画像（ユーザー提供、2026-07-11撮影）と並べて「ボタンが背景と被る」症状が解消したか直接比較する
4. VoiceOver ONで新規/変更ボタンのアクセシビリティラベル読み上げ確認
5. `Docs/UI_モックアップ.html`をブラウザで開き実装後の見た目と比較

---

## 未確定事項（要ユーザー判断・実装前に確認推奨）

- モード切替を自作`ButtonStyle`のグループ化で作るか、ネイティブ`Picker(.segmented)`に置き換えるか（後者はキーボード操作・アクセシビリティがOS標準になる利点があるが、`.help()`ツールチップの個別ボタン単位表示や現行の`ForEach`によるレジストリ動的生成との相性を実装時に検証する必要がある）
- `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`採用の可否は実機比較後に確定（本プランでは検証ステップとして残し、結論を後追いで記録する）
