# サイドバーモード：左カラムを閉じられなくする

**Status:** pending approval
**Mode:** Direct

---

## Requirements Summary

サイドバーモード（`SidebarModeView`）の左カラム（写真一覧）は、ドラッグ操作等で完全に閉じられる（非表示になる）べきではない。幅の下限は既存の120pt維持で確定（ユーザー確認済み）。今回のスコープは「閉じられない」ようにする部分のみ。

---

## 現状（コード調査結果）

- `ShootLog/Features/Viewer/Views/SidebarModeView.swift:6` — `@State private var columnVisibility = NavigationSplitViewVisibility.all` としてローカル`@State`で保持。
- 同ファイル13行目で `NavigationSplitView(columnVisibility: $columnVisibility)` にバインディングとして渡している。
- 同ファイル16行目 `.navigationSplitViewColumnWidth(min: 120, ideal: sidebarWidth, max: 400)` — 幅の下限120ptは既存。ただしこれは「ドラッグ可能な幅の範囲」の制約であり、NavigationSplitViewのネイティブ挙動として**ドラッグで閾値を超えるとカラム自体が非表示（collapse）になり`columnVisibility`が書き換わる**問題は別物。現状は`columnVisibility`が可変な`@State`のため、この収縮が起きると左カラムが消える。
- `columnVisibility` は `SidebarModeView.swift` 内でのみ宣言・使用されており、他ファイルからの参照・トグルボタンは存在しない（`grep`で確認済み。ツールバーにサイドバー開閉ボタンは実装されていない）。
- したがって「閉じられる」経路は、ネイティブのドラッグ収縮ジェスチャーのみ。

---

## Implementation Steps

### Step 1 — `columnVisibility` を固定バインディングにする

**File:** `ShootLog/Features/Viewer/Views/SidebarModeView.swift`

- 6行目 `@State private var columnVisibility = NavigationSplitViewVisibility.all` を削除。
- 13行目 `NavigationSplitView(columnVisibility: $columnVisibility)` を `NavigationSplitView(columnVisibility: .constant(.all))` に変更。
- 理由：`columnVisibility`を書き換え不可の定数バインディングにすることで、ドラッグ収縮ジェスチャーが発生してもSwiftUI側が状態を書き戻せず、左カラムは常に表示され続ける。幅のドラッグリサイズ自体（120〜400ptの範囲内）は`navigationSplitViewColumnWidth`が別途担っており、影響を受けない。

### Step 2 — 動作確認

- `run`スキル、または手動でアプリを起動しサイドバーモードに入る。
- 左カラムとビューアの境界線を最小幅（120pt）方向へ強くドラッグし、それ以上収縮しようとしても左カラムが消えない（非表示にならない）ことを確認。
- 通常のドラッグリサイズ（120〜400ptの範囲内）が引き続き機能することを確認。
- サイドバー幅の永続化（`@AppStorage("sidebarWidth")`）・矢印キーでの写真選択切替に回帰がないことを確認。
- フルスクリーンモード・スライドショーモードは`NavigationSplitView`を使わないため影響なし（コード上、両モードのビューにcolumnVisibility関連コードは存在しない）。

---

## Acceptance Criteria

1. `SidebarModeView.swift`の`NavigationSplitView`が`.constant(.all)`でバインドされており、`columnVisibility`という可変`@State`プロパティが存在しない（コード確認）。
2. サイドバーモードで左カラムをドラッグ収縮させようとしても、左カラムが非表示にならない（実機操作確認）。
3. 左カラムの幅は120〜400ptの範囲でドラッグリサイズが引き続き可能（実機操作確認、既存機能の回帰なし）。
4. サイドバー幅の`@AppStorage`永続化・上下矢印キーでの選択切替に回帰がない（実機確認）。
5. ビルドが成功する。

---

## Risks and Mitigations

| リスク | 対策 |
|--------|------|
| `.constant(.all)`化により、将来的に意図的なサイドバー開閉機能（トグルボタン等）を追加したくなった場合に再度可変バインディングへ戻す変更が必要 | 現状ツールバーに開閉ボタンは存在せず、CLAUDE.mdスケルトンの`toggleSidebarPanel`も未実装。将来必要になれば`@State`に戻し、明示的なトグルUIから制御する設計に変更すればよい（今回はスコープ外） |
| macOSのNavigationSplitViewネイティブ挙動（ダブルクリックでの収縮等）が`.constant`で完全に抑止できない可能性 | Step2の実機確認で収縮ジェスチャーが実際に無効化されることを検証する。もし抑止できないケースが見つかった場合は`onChange`的な監視・スナップバック方式へのフォールバックを検討（追加調査が必要） |

---

## Verification Steps

1. Xcodeでビルドが成功することを確認。
2. `run`スキルまたは手動起動でサイドバーモードに入り、Acceptance Criteria 2〜4を実機操作で確認。
3. ライト/ダークモード両方で見た目に問題がないことを確認（変更は挙動のみで見た目に影響しない想定だが念のため）。
