# サイドバー：閉じるボタン再発 + ドラッグ収縮再発の修正（回帰対応）

**Status:** pending approval
**Mode:** Direct

---

## 背景

過去プラン `sidebar-lock-visibility.md`（`columnVisibility` を `.constant(.all)` 化）と
`2026-07-12-remove-sidebar-toggle-and-fix-drag-collapse.md`（`.toolbar(removing: .sidebarToggle)` 追加 +
`SplitViewCollapseGuard` 新設）は**すでにコードに実装済み**（`SidebarModeView.swift:13,81`,
`SplitViewCollapseGuard.swift` 現存を実測確認）。

しかし添付スクリーンショット2枚により、対策後も同じ2つの症状が再現していることが確認された：

1. サイドバーモードのツールバー左端に「閉じるボタン」に見えるアイコンが表示される。
2. サイドバー境界線をドラッグすると左カラムが非表示になることがある。

過去プランの対策は方向性としては正しいが、**実装範囲・堅牢性が不十分**なため再発している。
本プランは新しい根本原因を特定し、追加修正を行う。

---

## 現状調査（コード実測・新規判明分）

### 症状1：閉じるボタン再発の原因

- `SidebarModeView.swift:81` に `.toolbar(removing: .sidebarToggle)` は確かに存在する。
- しかし `ContentView.swift:70-123` が**別スコープで独自の `.toolbar { ... }`** を持ち、
  その中に `ToolbarItemGroup(placement: .navigation)`（76-89行目、モード切替の3ボタン）を配置している。
  `ContentView` は `SidebarModeView` の**親**であり（`ContentView.swift:34-35` で
  `ViewModeRegistry.shared.mode(for:)?.makeView(vm:)` が返す `AnyView` として子を包む）、
  子スコープでの `removing:` 指定は、親スコープが独自にnavigation配置のツールバー内容を
  供給しているウィンドウ側のツールバー組み立てには及ばない。結果、macOSは
  `NavigationSplitView` の存在を検知して標準サイドバートグルを**ContentViewのnavigation配置グループの手前**
  （最左）に自動再挿入してしまう。
- 決定的証拠：`ViewModeRegistry.swift:30` で `SidebarMode.symbolName = "sidebar.left"`。
  これは macOS 標準サイドバートグルと**同一のSF Symbol**。スクリーンショット2枚目でユーザーが
  赤枠で囲った最左アイコン（＝ネイティブ自動挿入トグル）と、その右の青ハイライト
  アイコン（＝選択中の`SidebarMode`自身のボタン、同じ`sidebar.left`アイコン）が
  見た目上ほぼ同一になり、二重に見える現象と完全に一致する。

### 症状2：ドラッグ収縮再発の原因

- `SplitViewCollapseGuard.swift:17-24` の `viewDidMoveToWindow()` は**ウィンドウにアタッチされた
  タイミングで一度だけ**、`DispatchQueue.main.async` で1フレーム遅延させて
  `disableCollapseForOwnSplitViewItem()` を実行する。
- `disableCollapseForOwnSplitViewItem()`（26-45行目）は `splitView.delegate as? NSSplitViewController`
  が取得できない場合、**何もせず静かにreturnする**（42行目 `guard ... else { return }`）。
  リトライ機構が無い。
- `NavigationSplitView` → `NSSplitViewController` の内部階層構築が、1フレーム遅延後の時点でも
  完了していないケース（ウィンドウ復元・モード切替直後の再構築・初回起動時のレイアウト
  タイミング等）では `canCollapse = false` が一度も適用されないまま終わり、以後リトライされない。
  これが「稀に」「ドラッグで非表示になることがある」という非決定的な再現条件と一致する。

---

## 修正方針

### A. ツールバー除去指定を `ContentView` 側にも追加する

**File:** `ShootLog/Features/Library/Views/ContentView.swift`

- 独自 `.toolbar { ... }`（70-123行目）を持つ `ContentView` の body チェーンに
  `.toolbar(removing: .sidebarToggle)` を追加する（`.toolbarBackground`/`.toolbarColorScheme`
  付近、125-126行目周辺）。
- `SidebarModeView.swift:81` の既存指定はそのまま残す（冗長だが無害、フェイルセーフとして維持）。
- フルスクリーン/スライドショーモード時は `NavigationSplitView` が存在しないため、
  この指定は単純にno-opとなり副作用は無い。

### B. `SplitViewCollapseGuard` をレイアウトパス駆動の継続適用に変更する

**File:** `ShootLog/Shared/UI/SplitViewCollapseGuard.swift`

- 一度きりの `viewDidMoveToWindow` + 単発 `DispatchQueue.main.async` 方式をやめ、
  `NSView.layout()` をオーバーライドして**レイアウトが走るたびに**
  `disableCollapseForOwnSplitViewItem()` を呼ぶ方式に変更する。
  - `canCollapse = false` の再代入は冪等かつ極めて軽量（Bool代入のみ）なため、
    毎レイアウトパスで呼んでもパフォーマンス上の懸念はない。
  - `NSSplitViewController` 階層がまだ構築されていない初回レイアウトでは静かにno-opし、
    階層構築完了後の次のレイアウトパスで自動的に成功する（リトライを明示実装せずとも
    レイアウトの度に再試行される構造になる）。
  - `viewDidMoveToWindow()` のオーバーライドは残し、初回アタッチ時にも
    `needsLayout = true` をトリガーして早期に1回目の適用機会を作る。

### C. スコープ確認（変更なし）

- `NavigationSplitView` は `SidebarModeView` にのみ存在。修正A・Bとも
  フルスクリーン/スライドショーモードには影響しない。

---

## Implementation Steps

1. `ShootLog/Features/Library/Views/ContentView.swift`
   - body チェーン末尾付近（`.toolbarColorScheme(.dark, for: .windowToolbar)` の後）に
     `.toolbar(removing: .sidebarToggle)` を追加。
2. `ShootLog/Shared/UI/SplitViewCollapseGuard.swift`
   - `GuardView` に `override func layout()` を追加し、`super.layout()` 呼び出し後に
     `disableCollapseForOwnSplitViewItem()` を呼ぶ。
   - `viewDidMoveToWindow()` 内の処理を「`needsLayout = true` を設定して次のレイアウトパスに
     処理を委ねる」形に簡略化する（`DispatchQueue.main.async` は不要になるため削除）。
3. ビルド確認（Xcode）。
4. 実機動作確認（Verification Steps参照）。

---

## Acceptance Criteria

1. サイドバーモードのツールバーに、モード切替の3ボタングループ以外に
   サイドバートグル風のアイコンが表示されない（実機目視確認、`sidebar.left`アイコンが
   1個だけ＝モード切替ボタンのみであること）。
2. サイドバーモードで左カラム/中央カラムの境界線を最小幅（120pt）方向へ、
   様々な速度・タイミング（起動直後・モード切替直後を含む）で複数回強くドラッグしても、
   左カラムが非表示にならない。
3. 境界線のダブルクリックでも左カラムが非表示にならない。
4. 通常のドラッグリサイズ（120〜400ptの範囲内）は引き続き機能する（回帰なし）。
5. サイドバー幅の `@AppStorage("sidebarWidth")` 永続化・上下矢印キーでの写真選択切替に回帰がない。
6. フルスクリーンモード・スライドショーモードの見た目・挙動に変化がない。
7. ビルドが成功する（警告なし）。

---

## Risks and Mitigations

| リスク | 対策 |
|--------|------|
| `.toolbar(removing:)` を親子2箇所に指定することで、将来どちらかを削除した際に再発を見落とすリスク | 本プランのコメントで両方の指定意図（親＝実効箇所、子＝フェイルセーフ）を明記し、削除時は必ずどちらか一方が残ることをコードコメントで明示する |
| `layout()` を毎回呼ぶことによる潜在的な過剰実行 | `canCollapse = false` の代入のみで副作用が無く、AppKitのレイアウトパス自体はユーザー操作やアニメーションに応じた自然な頻度で発生するため、体感できるパフォーマンス影響は無い想定。実機確認でカクつきが無いことを確認する |
| `NSSplitView`/`NSSplitViewController` 階層特定ロジック自体は非公開実装依存のまま（既存プランのリスクを継承） | 既存の祖先ビュー一致方式・no-opフェイルセーフは維持。加えて`.constant(.all)`によるSwiftUI側抑止が最終防波堤として引き続き機能する |

---

## Verification Steps

1. Xcodeでビルドが成功することを確認。
2. アプリを起動し、フォルダを開いて即座にサイドバーモードに入る（起動直後のタイミングを狙う）。
3. ツールバー左端を目視し、サイドバートグル風アイコンが1個（モード切替ボタンのみ）であることを確認。
4. 境界線を掴み、最小幅を超えて強く・素早くドラッグする操作を、起動直後・モード切替直後・
   通常操作時それぞれで複数回試し、左カラムが消えないことを確認。
5. 境界線をダブルクリックしても左カラムが消えないことを確認。
6. フルスクリーンモード→サイドバーモードの往復切替を数回行った直後にも症状2が再現しないことを確認。
7. 通常範囲（120〜400pt）のドラッグリサイズが正常動作し、`@AppStorage`に幅が保存されることを確認。
8. 上下矢印キーでの写真選択切替に問題がないことを確認。
9. フルスクリーンモード・スライドショーモードに切り替えて、表示・操作に変化がないことを確認。
10. ライト/ダークモード両方で見た目に問題がないことを確認。

---

## ADR（簡易）

- **Decision:** サイドバートグル除去指定は `SidebarModeView`（子）だけでなく `ContentView`（親、
  実際のウィンドウツールバー組み立て箇所）にも付与する。収縮防止は単発非同期実行ではなく
  `NSView.layout()` 駆動の継続適用に変更する。
- **Drivers:** 過去プランの対策が実装済みにもかかわらず再発している事実。再発の原因が
  「適用スコープ不足」（症状1）と「単発実行のタイミング競合」（症状2）という構造的な
  問題であること。
- **Alternatives considered:**
  - 症状1: `SidebarModeView` 側の指定を削除して `ContentView` 側のみに一本化する案 →
    採用せず。冗長でも両方に残すフェイルセーフの方が、将来のリファクタで
    どちらかが誤って外れても安全側に倒れる。
  - 症状2: `NSSplitViewDelegate` の `splitView(_:canCollapseSubview:)` を実装する案 →
    `NavigationSplitView` がdelegateを内部的に占有しており、SwiftUI側から
    delegateを差し替える公開手段が無いため不採用。`layout()`駆動によるポーリング的
    継続適用の方が現実的。
- **Why chosen:** 既存実装への追加変更のみで完結し、既存のフェイルセーフ構造
  （no-op安全設計・`.constant(.all)`多層防御）を壊さない。
- **Consequences:** `SplitViewCollapseGuard`が毎レイアウトパスでAppKit階層を軽く歩くため、
  理論上はわずかな追加コストがあるが、Bool代入のみで無視できる範囲。
- **Follow-ups:** 将来 macOS のバージョンアップで `NavigationSplitView` の内部実装
  （`NSSplitViewController`/`NSSplitView`構造）が変わった場合は、本ガードの
  祖先ビュー一致ロジックを再検証すること。

---

## Changelog

- 初版作成（過去2プランの実装済み内容を実測確認した上での回帰修正プラン）。
