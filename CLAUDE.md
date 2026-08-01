# ShootLog — CLAUDE.md

Claude Codeへの指示書。実装前に必ず読むこと。
詳細な背景・設計根拠は `Docs/ShootLog_プロジェクト規約書.md` を参照。
UIの参考は `Docs/UI_モックアップ.html` を参照。

---

## プロジェクト概要

macOS ネイティブの写真管理ツール。
- EXIFデータ自動取得 → 撮影設定の傾向をグラフで振り返る
- 画像ビューア（フルスクリーン・スライドショー・サイドバー）としても使える
- 対象OS: macOS 14 Sonoma 以降（macOS 26 Tahoe でリキッドグラス対応）

---

## Xcodeプロジェクト設定

| 項目 | 値 |
|------|----|
| Bundle ID | `com.shootlog.app` |
| Deployment Target | macOS 14.0 |
| Swift | 6.0 |
| App Sandbox | 有効 |

### 必須 Entitlements

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
```

---

## 言語・識別子ルール（最重要）

**ファイル名・型名・関数名・変数名・引数名はすべて英語。コメントはすべて日本語。**

```swift
// ✅ 正しい
// 写真一覧を表示するメインビュー
struct LibraryView: View { }

// 指定フォルダからEXIFを非同期で取得する
func fetchEXIF(from url: URL) async throws -> EXIFInfo { }

// ❌ 禁止
struct 写真リストビュー: View { }
func EXIF情報を取得する(url: URL) async throws -> EXIF情報 { }
```

---

## アーキテクチャ

MVVM。レイヤーの責務を厳守する。

```
View（SwiftUI）        — レイアウト・表示のみ。ロジック禁止
  └─ ViewModel         — @Observable + @MainActor。状態管理
       └─ Model        — SwiftData @Model エンティティ
            └─ Service — EXIF取得・ファイルI/O・キャッシュ
```

### ViewModelの書き方

```swift
// 写真ライブラリ画面のViewModel
@Observable
@MainActor
final class LibraryViewModel {
    var photos: [Photo] = []
    var isLoading: Bool = false
    var error: (any Error)?

    // 指定フォルダから写真を読み込む
    func loadPhotos(from folderURL: URL) async {
        isLoading = true
        defer { isLoading = false }
        do {
            photos = try await PhotoRepository.shared.load(from: folderURL)
        } catch {
            self.error = error
        }
    }
}
```

---

## 非同期処理

- `async/await` のみ使う。`Combine` と `DispatchQueue` は禁止
- ファイルI/O・ネットワークは `Task.detached(priority: .utility)` でバックグラウンド実行
- メインスレッド（`@MainActor` 内）でファイルアクセスしない

```swift
// ✅ 正しいバックグラウンドI/O
let thumbnail = await Task.detached(priority: .utility) {
    // ImageIOでサムネイル取得
}.value

// ❌ 禁止：@MainActor内でのファイルアクセス
@MainActor func load() {
    let data = try! Data(contentsOf: url) // NG
}
```

---

## 対応画像フォーマット

| 種別 | 拡張子 |
|------|--------|
| RAW | `.nef` `.dng` `.arw` `.cr3` `.raf` |
| JPEG | `.jpg` `.jpeg` |
| その他 | `.heic` `.tiff` `.png` |

フォルダ直下のファイルのみ対象（サブフォルダは再帰読み込みしない）。
上記以外の拡張子はスキップ（エラーにしない）。

---

## 画像ロード戦略（3ステップ）

```
Step 1: ファイルURL一覧のみ即時取得 → グリッドにプレースホルダー表示
Step 2: AsyncStream でサムネイルをバックグラウンド取得 → 順次差し替え
Step 3: 選択・分析が必要な写真のEXIFのみ遅延取得
```

サムネイルは `NSCache<NSURL, NSImage>` でメモリキャッシュ。手動クリアしない。
ImageIO でサムネイル取得する際は `kCGImageSourceThumbnailMaxPixelSize: 256` を指定（フルサイズ読み込み禁止）。

---

## フォルダアクセス（セキュリティスコープ）

フォルダ選択時は必ずブックマークを保存する。これをしないと再起動後に履歴が使えない。

```swift
// 選択時：ブックマーク保存
let bookmark = try url.bookmarkData(
    options: .withSecurityScope,
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)

// 再アクセス時：ブックマークから復元
var stale = false
let restoredURL = try URL(
    resolvingBookmarkData: bookmark,
    options: .withSecurityScope,
    relativeTo: nil,
    bookmarkDataIsStale: &stale
)
restoredURL.startAccessingSecurityScopedResource()
defer { restoredURL.stopAccessingSecurityScopedResource() }
```

---

## UIルール

- ライト・ダークモード両対応必須。ハードコードカラー禁止
- セマンティックカラー（`Color(.label)` 等）または Assets.xcassets のカラーセットを使う
- macOS 26以降のリキッドグラスは `#available(macOS 26, *)` で条件分岐
- すべての操作可能要素に `.accessibilityLabel` を付与する
- フルスクリーン・スライドショーモードの背景は `.black`

---

## エラー処理

エラーはすべて `ShootLogError` enum で定義し `LocalizedError` に準拠させる。
`try!` は禁止。`try?` は戻り値を使わない場合のみ可。

エラー表示のUXルール：
- **操作の直接結果**（フォルダ読み込み失敗など）→ `Alert`
- **バックグラウンド処理の失敗**（サムネイル取得失敗など）→ インラインバナー
- **一時的な成功通知**（お気に入り登録など）→ Toast（2秒で自動消去）

---

## Sigma fp L カラーモード対応

Sigma fp L の PictureMode（EXIF/DNGカラーモード読み取り・表示）実装時は `sigma-color-mode` スキルを参照。

---

## 実装フェーズ（順番通りに進める）

| Phase | 実装内容 |
|-------|---------|
| 1 | Xcodeプロジェクト作成・Entitlements設定・SwiftDataモデル定義 |
| 2 | フォルダ読み込み（D&D + OpenPanel）・セキュリティブックマーク・フォルダ履歴 |
| 3 | EXIFService・ImageLoader（3ステップロード）・サムネイルグリッド表示 |
| 4 | お気に入り・メモ・SwiftData永続化 |
| 5 | ViewModeProtocol・ViewModeRegistry・SidebarModeビュー実装 |
| 6 | FullscreenMode・SlideshowMode |
| 7 | 基本編集（回転・トリミング、非破壊）|
| 8 | Swift Charts 分析グラフ（絞り・SS・ISO分布） |
| 9 | カメラ別比較・お気に入りvs全体ビュー |
| 10 | ネットワークドライブ最適化 |
| 11 | 外部アプリ連携（アダプター実装） |
| 12 | リキッドグラスUI・磨き込み |

**各Phaseは単体で動作確認できる状態にしてからコミットする。**

---

## Gitコミットルール

形式: `種別: 変更の概要`（日本語）

```
追加: サムネイルグリッド表示を実装
修正: EXIF読み取り時のクラッシュを修正
変更: ImageLoaderをactorに移行
```

種別: `追加` `修正` `変更` `削除` `設定` `文書`

---

## UIリファレンス

参考HTMLモックアップ: `Docs/UI_モックアップ.html`（全画面・色・レイアウト・インタラクションを網羅）

---

## やってはいけないこと

- ファイル名・型名・関数名・変数名に日本語を使う（コメントのみ日本語可）
- `ObservableObject` / `@Published` の使用（`@Observable` に統一）
- `Combine` / `DispatchQueue` の直接使用（`async/await` に統一）
- `try!` の使用
- `@MainActor` 内でのファイルアクセス
- 元ファイルの上書き（編集情報はSwiftDataに保存）
- ハードコードされた色値
- サブフォルダの再帰読み込み
- セキュリティスコープブックマークなしでの履歴フォルダアクセス

## その他
### 表示モードの拡張設計

新モードを追加するときは `ViewModeProtocol` に準拠した型を作り、`ViewModeRegistry` に1行追加するだけ。ツールバー・設定画面は変更不要。

`ViewModeProtocol` は `makeView` を持たない。ViewModelがView型を直接生成するとMVVM違反になるため、
モード切替はView側（`ContentView`）が `currentModeID` を見てswitchする設計になっている。

```swift
// 全表示モードが準拠するプロトコル。View生成(makeView)は持たない:
// ViewModelがView型を知る設計を避けるため、モード切替はView側(ContentView)が
// currentModeIDを見てswitchする
protocol ViewModeProtocol: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }           // SF Symbols名
    var keyboardShortcut: KeyEquivalent? { get }
}

// 初期登録モード
// SidebarMode     (id: "sidebar")   ← デフォルト
// FullscreenMode  (id: "fullscreen")
// SlideshowMode   (id: "slideshow")
```