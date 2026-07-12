# プラン: フォルダ選択時の先頭写真自動選択 + 上部ツールバー常時黒化

Status: **pending approval**
Date: 2026-07-12

## 要件サマリー

1. フォルダを開いた（選択/D&D/履歴復元）とき、写真一覧の先頭画像がデフォルトで選択された状態にする。
2. アプリ上部（タイトルバー統合ツールバー）を常に黒で表示する。現状、システムのライト/ダーク・非アクティブウィンドウ状態・アクセントカラーの影響で黒以外の色（青みがかったアクセント色・グレーの半透明マテリアル等）が出ることがある。

## 現状調査で判明した事実

- 実際に使われている画面は `ContentView` → `MainViewModel` の経路のみ。
  `ShootLog/Features/Library/Views/LibraryView.swift` と `ShootLog/Features/Library/ViewModels/LibraryViewModel.swift` はどこからも呼ばれていない未使用コード（`grep -rln "LibraryView("` で参照元が自分自身のみ）。今回のスコープ外、触らない。
- **選択の欠落**: `MainViewModel.swift:264-281` の `loadFolderPhotos(_:)` は `selectedPhoto = nil`（268行目）で毎回リセットし、277行目で `syncPhotos(urls:context:)` を呼んで `photos` を確定させるが、その後に選択をセットする処理が一切ない。
  - `selectPhoto(_:)`（`MainViewModel.swift:110-115`）が既存の選択メソッドで、`selectedPhoto` 更新に加え EditInfo ロード・EXIF遅延ロードまで面倒を見る。これを呼べば良い。
  - `loadFolderPhotos` は `selectFolder(url:)`（238-253行目）と `restoreFolder(_:)`（65-97行目）の両方から呼ばれる共通経路なので、ここ一箇所を直せばフォルダ選択・D&D・履歴復元の全経路をカバーできる。
- **黒色崩れの原因**: `ShootLog/App/ShootLogApp.swift:13` の `.windowToolbarStyle(.unifiedCompact(showsTitle: false))` のみでツールバー/タイトルバーの背景色を明示的に固定していない。システム標準のunified toolbarマテリアルに委ねているため、ライト/ダーク切替・ウィンドウ非アクティブ時・デスクトップ背景の透過などで色が揺れる。
  - `ShootLog/Shared/UI/DesignSystem.swift:143-148` の `toolbarButtonAppearance(isSelected:)` が選択中モードボタンに `Color.accentColor`（未カスタマイズのためデフォルトの青）を背景・前景に使っている → 選択中ボタンが青くなる。
  - `ShootLog/Features/Library/Views/ContentView.swift:88` のモード切替グループの外枠背景が `.background(.quaternary, ...)` → システム適応グレーで、ライトモード時に明るいグレーになりうる。
  - 同ファイル同箇所付近に `Color.onDarkCanvas` / `Color.onDarkCanvasSecondary`（`DesignSystem.swift:114-118`）という「黒背景キャンバス専用の固定色」が既に定義済み・コメントでも用途が明記されている。ツールバー用の固定色にはこれらを流用するのが筋が良い。

## 実装方針

### 機能1: フォルダ選択時に先頭写真を自動選択

`MainViewModel.swift` の `loadFolderPhotos(_:)` 内、277行目の `syncPhotos(urls: urls, context: context)` 呼び出し直後に以下を追加:

```swift
selectPhoto(photos.first)
```

- `photos` が空なら `photos.first` は `nil` となり `selectPhoto(nil)` が呼ばれる（`selectPhoto` はnilを許容し `currentEditInfo = nil` だけセットして早期returnするので安全、268行目で既にnilリセット済みとも整合）。
- `selectFolder` / `restoreFolder` どちらの経路でも `loadFolderPhotos` を通るため、1箇所の変更で両方カバーする。
- D&D経路（`handleProviderDrop`）も内部的に同じ `loadFolderPhotos` を通るか要確認（未確認点、実装時に軽く追跡する）。

### 機能2: 上部ツールバーを常時黒に固定

SwiftUIのAPIレベルで解決する（AppKitブリッジ・NSWindow直接操作は不要、CLAUDE.mdの「必要以上の複雑化をしない」方針にも合致）。

1. **ツールバー自体の背景・配色を固定**
   `ContentView.swift` の `body` に以下を追加（`.toolbar { ... }` の並び、`Group` に対して）:
   ```swift
   .toolbarBackground(Color.black, for: .windowToolbar)
   .toolbarColorScheme(.dark, for: .windowToolbar)
   ```
   - これはツールバー領域だけをダーク配色・黒背景に固定する。ウィンドウの残りのコンテンツ（`EmptyStateView`、`AnalysisView`のシート、アラート等）のライト/ダーク適応には影響しない ＝ CLAUDE.mdの「ライト・ダークモード両対応必須」ルールと矛盾しない。
   - macOS 14 SDKで利用可能なAPI（要実装時に実機/シミュレータで確認）。

2. **選択中モードボタンの色をアクセント色→固定色に変更**
   `DesignSystem.swift:143-148` の `toolbarButtonAppearance(isSelected:)` を修正:
   ```swift
   func toolbarButtonAppearance(isSelected: Bool = false) -> some View {
       frame(width: 28, height: 22)
           .background(isSelected ? Color.onDarkCanvas.opacity(0.18) : Color.clear)
           .foregroundStyle(isSelected ? Color.onDarkCanvas : Color.onDarkCanvasSecondary)
           .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
   }
   ```
   （`Color.onDarkCanvas` = 固定 `.white`、`onDarkCanvasSecondary` = `.white.opacity(0.7)`。既存定義を流用するだけで新規カラー追加不要）

3. **モード切替グループの外枠背景を固定色に変更**
   `ContentView.swift:88`:
   ```swift
   // 変更前
   .background(.quaternary, in: RoundedRectangle(cornerRadius: CornerRadius.medium))
   // 変更後
   .background(Color.onDarkCanvas.opacity(0.12), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
   ```

4. **境界線色の確認**
   `DesignSystem.swift:124` の `controlBorder`（`Color.primary.opacity(0.15)`）もツールバー内で使われている場合、`Color.primary` はライト/ダーク適応する可能性がある。実装時にツールバー内での使用箇所を確認し、黒背景上で使うなら `onDarkCanvasSecondary` 系の固定色に揃える（要調査、影響あれば追加修正）。

## Acceptance Criteria（受け入れ基準）

- [ ] フォルダを新規に開く（`openFolder`）と、写真一覧の先頭サムネイルが選択状態（枠付き）になり、右パネルにその写真のEXIF/ファイル名が表示される。
- [ ] フォルダ履歴から復元（`restoreFolder`）した場合も同様に先頭写真が自動選択される。
- [ ] D&Dでフォルダを開いた場合も同様に先頭写真が自動選択される。
- [ ] 空フォルダ（写真0件）を開いた場合はクラッシュせず、選択なし状態になる。
- [ ] ライトモード・ダークモード双方、かつウィンドウがアクティブ/非アクティブいずれの状態でも、上部ツールバー領域が常に黒で表示される（システムのアクセントカラーやグレーのマテリアルが透けない）。
- [ ] モード切替ボタン（サイドバー/ワイド等）の選択中ハイライトが青ではなく白系の固定色になる。
- [ ] `EmptyStateView`（フォルダ未選択時）やアラート・分析シートなど、ツールバー以外のコンテンツのライト/ダーク適応は従来通り機能する（今回の変更で壊れない）。

## リスクと対策

| リスク | 対策 |
|---|---|
| `.toolbarBackground`/`.toolbarColorScheme` がmacOS 14の `unifiedCompact` スタイルと組み合わせた際に期待通り効かない可能性（SwiftUIの当該APIはmacOSでの実効性にクセがある） | 実装後に実機ビルドでライト/ダーク切替・ウィンドウ非アクティブ化の3状態を目視確認。効かない場合はフォールバックとして `NSViewRepresentable` 経由の `NSWindow.titlebarAppearsTransparent` + `backgroundColor = .black` 方式に切り替える（CLAUDE.mdのDispatchQueue禁止ルールに従い `Task { @MainActor in }` で実装） |
| `selectPhoto(photos.first)` が既存のEXIF遅延ロード・EditInfoロードを毎回発火させ、大量ファイルのフォルダで初回ロードが重くなる懸念 | 元々ユーザーがサムネイルをクリックした時と同じ処理経路であり新規の重い処理ではない。実測で問題があれば別途最適化を検討（今回のスコープ外） |
| D&D経路 (`handleProviderDrop`) が `loadFolderPhotos` を通らない別経路の場合、そちらは自動選択が効かない | 実装時に `handleProviderDrop` の実装を確認し、必要なら同様の一箇所修正で対応 |

## 検証手順

1. Xcodeでビルドし実機/シミュレータで起動。
2. フォルダを新規オープン → 先頭サムネイルの選択枠とEXIFパネル表示を確認。
3. アプリを一度終了→再起動し、履歴から同フォルダを復元 → 先頭写真自動選択を確認。
4. D&Dで別フォルダをドロップ → 先頭写真自動選択を確認。
5. システム環境設定でライト/ダークを切り替えながらツールバーの色を確認（常に黒であること）。
6. ウィンドウをフォーカス解除（他アプリをクリック）してツールバーの色が変化しないことを確認。
7. モード切替ボタンをクリックし、選択中ハイライトが白系であり青くならないことを確認。

## 未確定点（実装時に調査が必要）

- D&Dが `loadFolderPhotos` を通るかどうかの経路確認。
- `.toolbarBackground`/`.toolbarColorScheme` の実機での効き具合（macOS 14 + `unifiedCompact` の組み合わせ実績が薄いため）。
- `controlBorder`（`Color.primary.opacity(0.15)`）がツールバー内で使われているかどうかの確認。
