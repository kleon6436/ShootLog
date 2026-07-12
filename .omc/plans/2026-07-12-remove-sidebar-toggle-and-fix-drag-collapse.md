# サイドバー：閉じるボタン廃止 + ドラッグ収縮バグ修正

**Status:** pending approval
**Mode:** Direct

---

## Requirements Summary

1. 左サイドバー（`SidebarModeView`）を閉じるボタンを無くす。
2. サイドバーの境界線をドラッグでリサイズした際、稀に左カラムが非表示（collapse）になってしまう不具合を修正する。サイドバーモードの間は常に表示され続けること。

---

## 現状調査（コード実測）

- `SidebarModeView.swift:13` — `NavigationSplitView(columnVisibility: .constant(.all))`。過去プラン `sidebar-lock-visibility.md` で `@State` バインディングから `.constant(.all)` に変更済み（SwiftUI側の`columnVisibility`書き換えを防ぐ対策）。同プランのリスク欄で「macOSのネイティブ挙動を完全に抑止できない可能性」を事前に指摘しており、今回の再発はこれが的中したもの。
- **アプリ内に独自の「閉じるボタン」コードは存在しない**（`close`/`hide`/`toggleSidebar`/`isSidebarVisible`/`sidebarToggle`等でgrep済み、ヒットなし）。`FullscreenModeView.swift:31`の`CloseButton`はフルスクリーン解除ボタンで別物。
  - つまりユーザーが見ている「閉じるボタン」は、**macOSが`NavigationSplitView`に対して自動的にツールバーへ挿入する標準の「サイドバー切り替え」ボタン**（タイトルバー左端のアイコン、AppKitの標準`toggleSidebar:`アクション）。SwiftUI側では`.toolbar(removing: .sidebarToggle)`（macOS 14+）で明示的に除去できる。本プロジェクトのDeployment TargetはmacOS 14.0のため利用可能。
- **ドラッグ収縮バグの根本原因**：`columnVisibility`を`.constant(.all)`にしても、AppKit側の`NSSplitViewItem.canCollapse`はデフォルト`true`のままであり、これは`columnVisibility`バインディングとは独立した挙動。ユーザーが分割線を最小幅（120pt）方向へ強くドラッグすると、AppKitのネイティブ収縮ジェスチャーがSwiftUIの`columnVisibility`制御を経由せずに直接カラムを畳んでしまう。SwiftUIには`canCollapse`を制御する公開APIが無いため、`NSViewRepresentable`でAppKit階層に手を伸ばして`canCollapse = false`を設定する必要がある。

---

## 修正方針

### A. 標準サイドバートグルボタンの除去

**File:** `ShootLog/Features/Viewer/Views/SidebarModeView.swift`

- `NavigationSplitView { ... }`（13〜74行目）の直後に `.toolbar(removing: .sidebarToggle)` を追加する。
- これによりmacOSが自動挿入するタイトルバーの「サイドバー切り替え」ボタンが消え、ユーザーがサイドバーを閉じる手段が無くなる。

### B. ドラッグ収縮の完全防止（AppKitブリッジ）

**New file:** `ShootLog/Shared/UI/SplitViewCollapseGuard.swift`

- `NSViewRepresentable`（`SplitViewCollapseGuard`）を新設。
  - `makeNSView`は透明な1x1の`NSView`サブクラス（`GuardView`）を返す。
  - `GuardView`は`viewDidMoveToWindow()`をオーバーライドし、`self.superview`を`NSSplitView`が見つかるまで遡る。
  - 見つかった`NSSplitView`の`delegate`（または`window?.contentViewController`を`NSSplitViewController`にキャストしたもの）から`splitViewItems`を取得し、**自分自身のビューを内包する`viewController.view`に一致する`item`**（＝サイドバー列自身のアイテム）を特定して`item.canCollapse = false`を設定する。
    - インデックス固定（`splitViewItems[0]`）ではなく祖先ビュー一致で特定することで、`NavigationSplitView`内部構造がOSバージョンで変わっても誤って中央/右カラムのアイテムを掴まない。
  - `NSSplitView`や対応する`NSSplitViewItem`が見つからない場合は何もしない（クラッシュさせず、静かにno-op）。
- `SidebarModeView.swift`の左カラム（`PhotoListView`、15〜48行目）に`.background { SplitViewCollapseGuard() }`を追加し、`GeometryReader`の背景と同様の手法でAppKit階層へ橋渡しする。

### C. スコープの確認

- `NavigationSplitView`は`SidebarModeView`にのみ存在し、フルスクリーン/スライドショーモードは別ビュー（`NavigationSplitView`不使用）のため、本修正はサイドバーモードにのみ影響する。ユーザー要望「サイドバーモードの時は非表示にしたくない」は構造上自動的に満たされる。

---

## Implementation Steps

1. `ShootLog/Shared/UI/SplitViewCollapseGuard.swift` を新規作成し、上記Bの`NSViewRepresentable`を実装する。
2. `ShootLog/Features/Viewer/Views/SidebarModeView.swift`
   - 13行目の`NavigationSplitView`直後（74行目の`}`の後）に`.toolbar(removing: .sidebarToggle)`を追加。
   - 左カラム（15〜48行目）の`.background(.regularMaterial)`と`GeometryReader`背景に加え、`.background { SplitViewCollapseGuard() }`を追加。
3. ビルド確認（Xcode）。
4. 実機動作確認（Verification Steps参照）。

---

## Acceptance Criteria

1. タイトルバーに標準の「サイドバー切り替え」ボタンが表示されない（実機確認）。
2. サイドバーモードで左カラムと中央カラムの境界線を最小幅（120pt）方向へ強くドラッグしても、左カラムが非表示にならない（実機操作確認、複数回・異なる速度でドラッグして再現しないことを確認）。
3. 境界線のダブルクリックでも左カラムが非表示にならない（AppKitのcanCollapse=falseはダブルクリック収縮ジェスチャーにも作用するため、合わせて確認）。
4. 通常のドラッグリサイズ（120〜400ptの範囲内）は引き続き機能する（回帰なし）。
5. サイドバー幅の`@AppStorage("sidebarWidth")`永続化・上下矢印キーでの写真選択切替に回帰がない。
6. フルスクリーンモード・スライドショーモードの挙動に変化がない（`NavigationSplitView`を使わないため無関係）。
7. ビルドが成功する（警告なし、`SplitViewCollapseGuard`のAppKit呼び出しがサンドボックス/権限に抵触しない）。

---

## Risks and Mitigations

| リスク | 対策 |
|--------|------|
| `NSViewRepresentable`でのAppKit階層遡りは`NavigationSplitView`の内部実装（`NSSplitViewController`/`NSSplitView`構造）に依存する非公開的な手法。OSアップデートで構造が変わると効かなくなる可能性がある | 祖先ビュー一致で対象アイテムを特定し、見つからない場合は静かにno-opするフェイルセーフ設計にする。将来のmacOSで動作しなくなった場合も、既存の`.constant(.all)`によるSwiftUI側の抑止は引き続き効いているため、致命的な回帰にはならない |
| `canCollapse = false`が中央/右カラムにも誤って適用されると、それらのカラムのユーザー操作性が変わる可能性 | 祖先ビュー一致方式で左カラムのアイテムのみを対象にする（Bで詳述） |
| `.toolbar(removing: .sidebarToggle)`はmacOS 14+限定API | Deployment TargetがmacOS 14.0のため問題なし |
| `viewDidMoveToWindow`のタイミングでまだ`NSSplitView`階層が完全に構築されていない場合、遡りが失敗する可能性 | `DispatchQueue.main.async`で1フレーム遅延させてから遡り処理を実行し、階層構築完了後に確実に実行されるようにする |

---

## Verification Steps

1. Xcodeでビルドが成功することを確認。
2. アプリを起動しサイドバーモードに入る。
3. タイトルバー左端にサイドバー切り替えボタンが**表示されない**ことを目視確認。
4. 左カラムと中央カラムの境界線を掴み、最小幅を超えて強く・素早くドラッグしても左カラムが消えないことを複数回確認。
5. 境界線をダブルクリックしても左カラムが消えないことを確認。
6. 通常範囲（120〜400pt）のドラッグリサイズが正常に機能し、`@AppStorage`に幅が保存されることを確認（アプリ再起動後も幅が近似復元される）。
7. 上下矢印キーでの写真選択切替に問題がないことを確認。
8. フルスクリーンモード・スライドショーモードに切り替えて、表示・操作に変化がないことを確認。
9. ライト/ダークモード両方で見た目に問題がないことを確認。
