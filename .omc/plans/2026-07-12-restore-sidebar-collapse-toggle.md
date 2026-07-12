# サイドバー開閉トグルボタンの復活 + ドラッグ収縮の正規サポート

**Status:** pending approval
**Mode:** Direct

---

## 背景・経緯

過去3プラン（`sidebar-lock-visibility.md` → `2026-07-12-remove-sidebar-toggle-and-fix-drag-collapse.md`（該当ファイル未発見だが内容は次のプランに統合済み）→ `2026-07-12-sidebar-toggle-and-collapse-regression-fix.md`）で、左カラム（サイドバー）は**意図的に完全ロック**された：

1. `columnVisibility` を可変 `@State` から `.constant(.all)` に変更（`SidebarModeView.swift:13`）
2. `.toolbar(removing: .sidebarToggle)` を `SidebarModeView`（子）・`ContentView`（親、実効スコープ）の両方に追加
3. `SplitViewCollapseGuard`（AppKitブリッジ）で `NSSplitViewItem.canCollapse` を毎レイアウトパスで強制 `false` にし、ネイティブの `toggleSidebar` `NSToolbarItem` を `NSToolbar` から物理的に除去

結果、現在は**サイドバーを閉じる手段が一切存在しない**。ユーザーが「閉じるボタンが機能しない」と報告したのは、`ContentView.swift:79` の表示モード切替ボタン（`sidebar.left` アイコン、`SidebarMode.symbolName`）をサイドバー開閉ボタンと誤認しているため（アイコンがネイティブのサイドバートグルと同一で紛らわしい）。実際にはこのボタンは Sidebar/Fullscreen/Slideshow の**表示モード切替**であり、開閉トグルではない。

ユーザーの要望（ヒアリング確認済み）：**サイドバー折りたたみ機能を復活させ、ドラッグ収縮の挙動も正しく機能するようにする。**

過去のロックは「ドラッグで意図せず消える」バグへの対処だったが、根本原因は次の2点であり、開閉機能そのものを禁止しなくても個別に解決可能：

- **症状1（アイコン重複）**：`.toolbar(removing:)` がSwiftUI側の子スコープのみだと、macOS 26でAppKitがネイティブ `toggleSidebar` を自動再挿入し、モード切替ボタンと紛らわしい形で重複表示される。
- **症状2（非決定的な消失)**：`SplitViewCollapseGuard` が `canCollapse = false` を強制していたこと自体は「消える」原因ではなく、むしろ「消えないようにする」ための処置だった。今回はこれを望ましい挙動として許可する。

---

## 現状（コード実測）

| ファイル | 行 | 内容 |
|---|---|---|
| `ShootLog/Features/Viewer/Views/SidebarModeView.swift` | 5-9 | `@Bindable var vm`, `@AppStorage sidebarWidth`, `widthSaveTask`, `isSidebarFocused` のみ。`columnVisibility` の `@State` は削除済み |
| 同上 | 13 | `NavigationSplitView(columnVisibility: .constant(.all))` |
| 同上 | 29-34 | `.background { SplitViewCollapseGuard() }` |
| 同上 | 81 | `.toolbar(removing: .sidebarToggle)` |
| `ShootLog/Features/Library/Views/ContentView.swift` | 76-89 | 表示モード切替3ボタン（`ToolbarItemGroup(placement: .navigation)`） |
| 同上 | 132 | `.toolbar(removing: .sidebarToggle)`（実効スコープ、症状1対策） |
| `ShootLog/Shared/UI/SplitViewCollapseGuard.swift` | 全体 | `layout()` 毎に `disableCollapseForOwnSplitViewItem()`（`canCollapse=false` 強制）+ `removeNativeSidebarToggleButton()`（ネイティブトグル除去）を実行 |
| `ShootLog/Viewer/ViewModeRegistry.swift` | 30 | `SidebarMode.symbolName = "sidebar.left"`（ネイティブトグルと同一アイコン、紛らわしさの元） |

---

## 修正方針

### A. `columnVisibility` を可変に戻す

**File:** `SidebarModeView.swift`

- `@State private var columnVisibility: NavigationSplitViewVisibility = .all` を復活。
- `NavigationSplitView(columnVisibility: $columnVisibility)` にバインディングを戻す。

### B. 明示的な開閉トグルボタンを追加する

**File:** `SidebarModeView.swift`

- `.toolbar { ToolbarItem(placement: .navigation) { Button { ... } label: { Image(systemName: "sidebar.left") } } }` を追加。
- アクション: `withAnimation(.easeInOut(duration: 0.2)) { columnVisibility = columnVisibility == .all ? .doubleColumn : .all }`
  - 3カラム構成（sidebar/content/detail）で左カラムのみ隠すのは `.doubleColumn`（`.detailOnly` は content も隠してしまうため不可）。
- `.help("サイドバーを開閉 (⌘\\)")` ・ `.accessibilityLabel("サイドバーを開閉")` を付与（CLAUDE.mdのUIルール準拠）。
- キーボードショートカット案: `⌘\`（macOS標準のサイドバートグルショートカット）を `.keyboardShortcut("\\", modifiers: .command)` で付与（既存の `⌘O` `⌘I` と衝突しないため安全）。

### C. モード切替ボタンのアイコンをサイドバートグルと区別する

**File:** `ShootLog/Viewer/ViewModeRegistry.swift:30`

- `SidebarMode.symbolName` を `"sidebar.left"` → `"rectangle.split.3x1"`（3カラムレイアウトを表す、サイドバー/ビューア/EXIFパネルの構成と意味的に一致）に変更。
- これにより開閉トグル（`sidebar.left`）とモード切替（`rectangle.split.3x1`）が視覚的に完全に分離され、症状1のような誤認が構造的に起きなくなる。

### D. `SplitViewCollapseGuard` からドラッグ収縮の抑止だけを外す

**File:** `ShootLog/Shared/UI/SplitViewCollapseGuard.swift`

- `disableCollapseForOwnSplitViewItem()` メソッドとその呼び出し（`layout()` 内）を削除。`NSSplitViewItem.canCollapse` はデフォルト `true` のため、何もしなければ自然にドラッグ収縮が機能する。
- `removeNativeSidebarToggleButton()` は**維持**（ステップCでアイコンは区別したが、ネイティブの `toggleSidebar` 自動挿入自体は引き続き止めないと、開閉トグル（自前）とネイティブトグルが両方表示され本当に重複するため）。
- 責務が「ネイティブトグル除去のみ」になるため、型名を `SplitViewCollapseGuard` → `NativeSidebarToggleRemover` にリネームし、ファイル名も `SplitViewCollapseGuard.swift` → `NativeSidebarToggleRemover.swift` に変更。古い「収縮を防ぐ」趣旨のコメントは削除し、「ネイティブトグルのみ除去する」現状に合わせて日本語コメントを更新。
- `SidebarModeView.swift:33` の参照 `SplitViewCollapseGuard()` → `NativeSidebarToggleRemover()` に追従。周辺コメント（29-34行目）も更新。

### E. スコープ確認（変更なし）

- フルスクリーン/スライドショーモードは `NavigationSplitView` を使わないため、A〜D の変更は影響しない。
- `ContentView.swift:132` の `.toolbar(removing: .sidebarToggle)` はそのまま維持（AppKit側の除去と二重のフェイルセーフとして有効、既存プランの設計思想を継承）。

---

## Implementation Steps

1. **`ShootLog/Viewer/ViewModeRegistry.swift`**
   - 30行目 `symbolName` を `"rectangle.split.3x1"` に変更。
2. **`ShootLog/Shared/UI/SplitViewCollapseGuard.swift`** → **`NativeSidebarToggleRemover.swift`** にリネーム
   - 型名を `NativeSidebarToggleRemover` に変更。
   - `disableCollapseForOwnSplitViewItem()` メソッドと `layout()` からの呼び出しを削除。
   - ファイル冒頭・`layout()` のコメントを、ネイティブトグル除去のみを行う現状に合わせて更新。
3. **`ShootLog/Features/Viewer/Views/SidebarModeView.swift`**
   - `@State private var columnVisibility: NavigationSplitViewVisibility = .all` を復活（5-9行目付近）。
   - 13行目を `NavigationSplitView(columnVisibility: $columnVisibility) {` に変更。
   - 12行目の「`.constant(.all)` 固定」コメントを削除し、可変管理である旨に更新。
   - 29-34行目の `SplitViewCollapseGuard()` 参照を `NativeSidebarToggleRemover()` に変更し、コメントを更新。
   - `.toolbar(removing: .sidebarToggle)`（81行目）の直前に、開閉トグルボタンの `.toolbar { ToolbarItem(placement: .navigation) { ... } }` を追加（方針B参照）。
4. Xcodeでビルド確認。
5. 実機動作確認（Verification Steps参照）。

---

## Acceptance Criteria

1. サイドバーモードのツールバーに、開閉トグルボタン（`sidebar.left`）とモード切替ボタン（`rectangle.split.3x1` 含む3ボタン）が別アイコンで共存し、ネイティブの重複トグルが表示されない（実機目視確認）。
2. 開閉トグルボタンをクリックすると左カラムが表示/非表示を正しくトグルする（中央・右カラムは常に表示のまま）。
3. 左カラム/中央カラムの境界線をドラッグして最小幅を超えて収縮させると、左カラムが正しく折りたたまれる（ネイティブ挙動として機能する）。
4. 折りたたんだ状態から開閉トグルボタンで再表示すると、元のサイドバー幅（`@AppStorage("sidebarWidth")`）が保たれている（ドラッグ収縮時の幅保存で壊れていないこと）。
5. 通常のドラッグリサイズ（120〜400ptの範囲内）は引き続き機能する（回帰なし）。
6. 上下矢印キーでの写真選択切替に回帰がない（サイドバーが表示されているときのみ機能すればよい）。
7. フルスクリーンモード・スライドショーモードの見た目・挙動に変化がない。
8. ライト/ダークモード両方で見た目に問題がない。
9. ビルドが成功する（警告なし）。

---

## Risks and Mitigations

| リスク | 対策 |
|---|---|
| `canCollapse` 制限を外すことで、過去プランが問題視した「意図せず消える」挙動が復活する | 今回は明示的な要望により許可される挙動。開閉トグルボタンで確実に復帰できるため、ユーザー操作の結果として一貫性がある（ネイティブSplitViewの標準挙動に準拠） |
| ドラッグで折りたたんだ直後、`GeometryReader` 経由の `scheduleWidthSave` が収縮途中の幅（0付近）を誤って `sidebarWidth` に保存してしまう可能性 | Verification Step で折りたたみ→再展開後に元の幅へ戻ることを実機確認する。もし壊れる場合は `columnVisibility == .all` の時のみ `onChange` を有効にするガードを追加する（今回のスコープでは事象確認後に追加判断） |
| `NativeSidebarToggleRemover` へのリネームでビルドエラー（参照漏れ） | `SidebarModeView.swift` 内の唯一の参照箇所を確実に更新し、ビルド確認で検出する |
| `rectangle.split.3x1` がSF Symbolsに存在しない/意味が伝わりにくい場合 | XcodeのSymbolピッカーで実在確認してから採用。代替候補: `"sidebar.squares.left"` |
| 開閉トグルのキーボードショートカット `⌘\` が既存ショートカットと衝突 | 既存は `⌘O`（フォルダ）・`⌘I`（分析）のみのため衝突なし。実装時に再確認 |

---

## Verification Steps

1. Xcodeでビルドが成功することを確認。
2. アプリを起動しサイドバーモードに入る。ツールバー左端に開閉トグル（`sidebar.left`）とモード切替3ボタン（先頭が `rectangle.split.3x1`）が別々に、重複なく表示されることを確認。
3. 開閉トグルボタンをクリックし、左カラムが非表示になる → 再クリックで表示に戻ることを確認。
4. 境界線を最小幅方向へドラッグし、左カラムが自然に折りたたまれることを確認。
5. 折りたたんだ状態から開閉トグルボタンで再表示し、サイドバー幅がドラッグ前と同じであることを確認（`@AppStorage`破壊がないか）。
6. 通常範囲（120〜400pt）のドラッグリサイズが正常動作し、幅が永続化されることを確認。
7. サイドバー表示中に上下矢印キーで写真選択が切り替わることを確認。
8. フルスクリーンモード・スライドショーモードに切り替えて表示・操作に変化がないことを確認。
9. ライト/ダークモード両方で見た目を確認。
10. Xcodeビルドの警告が増えていないことを確認。

---

## ADR（簡易）

- **Decision:** サイドバー開閉ロックを解除し、明示的な開閉トグルボタン + ネイティブドラッグ収縮の両方を正規サポートする。ネイティブトグルの自動挿入のみ引き続き抑止し、モード切替ボタンのアイコンを変更して視覚的重複を構造的に解消する。
- **Drivers:** ユーザーが開閉機能を明確に要望。過去のロックは「意図しない消失」対策であり、正規の開閉手段がない状態はUXの後退だった。
- **Alternatives considered:**
  - ロック状態を維持しモード切替ボタンの挙動だけ調査 → 不採用（ユーザーが開閉機能自体の復活を明確に希望）。
  - `SplitViewCollapseGuard` を完全削除しネイティブトグルの重複除去もやめる → 不採用（macOS 26実測でSwiftUI側`.toolbar(removing:)`だけでは重複が再発することが既に判明済み、実効性のあるAppKit直接除去は維持すべき）。
- **Why chosen:** 既存の多層防御構造（SwiftUI + AppKit）のうち「重複トグル除去」は維持しつつ「収縮禁止」だけを外す、最小差分での方針転換。
- **Consequences:** ドラッグ収縮が正式な挙動になるため、今後同種の「消えるバグ」報告が来た場合は「意図した開閉」か「実装不具合」かの切り分けが必要になる。
- **Follow-ups:** サイドバー幅保存ロジック（`scheduleWidthSave`）が折りたたみ操作と競合しないか、実機確認で問題が出た場合は別途ガード追加。

---

## Changelog

- 初版作成。過去3プランでロックされたサイドバー開閉機能をユーザー要望に基づき復活。
