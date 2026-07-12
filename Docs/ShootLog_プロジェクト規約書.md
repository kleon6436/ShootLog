# ShootLog — プロジェクト規約書

> 最終更新: 2026-06-27

---

## 1. プロジェクト概要

| 項目 | 内容 |
|------|------|
| アプリ名 | ShootLog（仮称） |
| 種別 | macOS ネイティブアプリ |
| 目的 | 写真のEXIFデータを自動取得し、撮影設定の傾向を統計・グラフで振り返る。画像ビューアとしても使える万能な写真管理ツール |
| 対象ユーザー | 複数カメラ（Nikon Zf / Leica SL2-S など）を使う写真愛好家 |

---

## 2. アーキテクチャ

### 2.1 パターン

**MVVM（Model-View-ViewModel）** を採用する。

```
View（SwiftUI）
  └─ ViewModel（@Observable / ObservableObject）
       └─ Model（SwiftData エンティティ・ドメインロジック）
            └─ Repository / Service（EXIF取得・ファイルI/O）
```

- View はレイアウトと表示のみを担当し、ロジックを持たない
- ViewModel は `@Observable` マクロを使用する（iOS 17 / macOS 14以降）
- Model とデータ取得処理は Repository / Service レイヤーに分離する

### 2.2 ディレクトリ構成

```
ShootLog/
├── App/
│   └── ShootLogApp.swift          # エントリーポイント
├── Features/
│   ├── Library/                   # 写真一覧・読み込み
│   │   ├── Views/
│   │   └── ViewModels/
│   ├── Viewer/                    # フルスクリーン・スライドショー・RAWプレビュー
│   │   ├── Views/
│   │   └── ViewModels/
│   ├── Editor/                    # 回転・トリミング（非破壊）
│   │   ├── Views/
│   │   └── ViewModels/
│   ├── Analysis/                  # グラフ・統計画面
│   │   ├── Views/
│   │   └── ViewModels/
│   └── Settings/
├── Models/
│   ├── Photo.swift
│   ├── EditInfo.swift
│   └── FolderHistory.swift
├── Services/
│   ├── EXIFService.swift
│   ├── PhotoRepository.swift
│   └── ImageLoader.swift          # 段階的ロード・キャッシュ管理
├── Integration/                   # 外部アプリ連携（将来拡張用）
│   ├── ExternalAppProtocol.swift  # 連携インターフェース定義
│   └── Adapters/                  # アプリごとの実装（CaptureOne等）
├── Shared/
│   ├── UI/                        # 共通コンポーネント
│   ├── Extensions/
│   └── ShootLogError.swift
└── Resources/
```

---

## 3. 技術スタック

| 分野 | 採用技術 | 備考 |
|------|----------|------|
| UI フレームワーク | SwiftUI | macOS 14（Sonoma）以降をターゲット |
| グラフ描画 | Swift Charts | Apple 純正・宣言的API |
| EXIF 読み取り | ImageIO フレームワーク | Apple 純正・追加依存なし |
| データ永続化 | SwiftData | `@Model` マクロベース |
| 非同期処理 | async/await（Swift Concurrency） | Combine は原則使用しない |
| 画像ロード | AsyncStream + NSCache | サムネイル先行・EXIF遅延取得 |
| Linter | SwiftLint | ルールは `.swiftlint.yml` で管理 |
| バージョン管理 | Git + GitHub | |
| 開発補助 | Claude Code | コード生成・リファクタリング |

### 3.1 最低対応OS

- macOS 14 Sonoma 以降
- リキッドグラスデザイン（macOS 26 Tahoe 以降の機能）は `@available` で条件分岐して採用する

---

## 4. コーディング規約

### 4.1 言語・識別子

- **ファイル名・型名・関数名・変数名・引数名：すべて英語**
- **コメント（`//`・`///`・`/* */`）：すべて日本語**
- Swift のキーワード、Apple フレームワーク名、業界略語（EXIF, ISO, URL, RAW, GPS 等）はそのまま英語

```swift
// ✅ 良い例
struct PhotoDetailView: View { ... }
func fetchEXIF(url: URL) async throws -> EXIFInfo { ... }

// ❌ 悪い例
struct 写真詳細ビュー: View { ... }
func EXIF情報を取得する(url: URL) async throws -> EXIF情報 { ... }
```

コメントの書き方：

```swift
/// 写真のEXIFデータをImageIOで取得するサービス
actor EXIFService {

    /// 指定URLの画像からEXIF情報を非同期で取得する
    /// - Parameter url: 対象ファイルのURL
    /// - Returns: 取得したEXIF情報。取得できない場合はnil
    func fetchInfo(from url: URL) async -> EXIFInfo? {
        // ImageIOでCGImageSourceを生成
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        // プロパティ辞書からEXIF値を抽出
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        return props.map { EXIFInfo(properties: $0) }
    }
}
```

### 4.2 async/await

- 非同期処理は `async/await` を使う。`Combine` や `DispatchQueue` の直接使用は避ける
- メインスレッドへの切り替えは `@MainActor` アノテーションで明示する
- Task のキャンセル処理を適切に実装する

```swift
// ✅ 良い例（@Observable マクロを使う）
@Observable
@MainActor
final class LibraryViewModel {
    var photos: [Photo] = []
    var error: Error?

    // 指定フォルダから写真を非同期で読み込む
    func loadPhotos(from folderURL: URL) async {
        do {
            photos = try await PhotoRepository.shared.load(from: folderURL)
        } catch {
            self.error = error
        }
    }
}

// ❌ 悪い例（ObservableObject は使わない）
// class LibraryViewModel: ObservableObject { ... }
```

### 4.3 エラーハンドリング

- エラーは `enum` で定義し、`LocalizedError` に準拠させる
- `try?` は戻り値を使わない場合のみ許可、`try!` は禁止

```swift
// アプリ全体で使用するエラー定義
enum ShootLogError: LocalizedError {
    case exifReadFailed
    case unsupportedFormat(extension: String)

    var errorDescription: String? {
        switch self {
        case .exifReadFailed:
            return "EXIF情報の読み取りに失敗しました"
        case .unsupportedFormat(let ext):
            return "未対応の形式です: \(ext)"
        }
    }
}
```

### 4.4 SwiftLint 設定方針

`.swiftlint.yml` で以下を基本方針とする：

```yaml
opt_in_rules:
  - force_unwrapping
  - empty_count
  - closure_spacing

line_length: 120
```

> 英語識別子に統一したため `identifier_name` の無効化は不要。

---

## 5. UIデザイン方針

### 5.1 基本方針

- **ネイティブ macOS デザインを最優先**とする
- Apple HIG（Human Interface Guidelines）に準拠する
- サードパーティの UIライブラリは原則使用しない

### 5.2 リキッドグラスデザイン

- macOS 26 Tahoe 以降で利用可能なリキッドグラスエフェクトを積極的に採用する
- 対応OS未満では `@available(macOS 26, *)` で条件分岐し、ネイティブな代替UIを提供する

```swift
Group {
    if #available(macOS 26, *) {
        // リキッドグラス対応のビュー
        SidebarContent()
            .glassBackgroundEffect()
    } else {
        // macOS 14-15 向けフォールバック
        SidebarContent()
            .background(.regularMaterial)
    }
}
```

### 5.3 カラースキーム

- ライト・ダークモード両対応を必須とする
- カラーはすべて `Color(nsColor:)` または Assets.xcassets のセマンティックカラーを使用する
- ハードコードされた色値（`Color(red:green:blue:)` 等）は禁止

### 5.4 アクセシビリティ

- すべての操作可能な要素に `.accessibilityLabel` を付与する
- Dynamic Type に対応した相対フォントサイズを使用する

---

## 6. データモデル（SwiftData）

```swift
// 写真1枚に対応するSwiftDataモデル
@Model
final class Photo {
    var id: UUID
    var fileURL: URL
    var shootingDate: Date
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var aperture: Double?       // F値
    var shutterSpeed: Double?   // 秒
    var iso: Int?
    var focalLength: Double?    // mm
    var colorMode: String?      // Sigma fp L 等のカラーモード名（例: "PowderBlue", "TealAndOrange"）
    var isFavorite: Bool
    var note: String

    init(id: UUID = UUID(), fileURL: URL) {
        self.id = id
        self.fileURL = fileURL
        self.shootingDate = Date()
        self.isFavorite = false
        self.note = ""
    }
}

// 非破壊編集情報（元ファイルは変更しない）
@Model
final class EditInfo {
    var photoID: UUID
    var rotation: Int           // 0 / 90 / 180 / 270
    var cropRect: CGRect?       // nil = トリミングなし（正規化座標 0.0〜1.0）
    var createdAt: Date

    init(photoID: UUID) {
        self.photoID = photoID
        self.rotation = 0
        self.createdAt = Date()
    }
}

// フォルダアクセス履歴（最大10件）
@Model
final class FolderHistory {
    var url: URL
    var securityBookmark: Data  // セキュリティスコープブックマーク（再起動後のアクセスに必須）
    var lastAccessedAt: Date
    var displayName: String     // url.lastPathComponent

    init(url: URL, bookmark: Data) {
        self.url = url
        self.securityBookmark = bookmark
        self.lastAccessedAt = Date()
        self.displayName = url.lastPathComponent
    }
}
```

---

## 7. Git 運用ルール

### 7.1 ブランチ戦略

```
main          # リリース可能な状態のみ
develop       # 開発の統合ブランチ
feature/機能名  # 機能開発ブランチ
fix/バグ名      # バグ修正ブランチ
```

### 7.2 コミットメッセージ

日本語で記述する。形式：`種別: 変更の概要`

| 種別 | 用途 |
|------|------|
| `追加` | 新機能・新ファイルの追加 |
| `修正` | バグ修正 |
| `変更` | 既存機能の変更・リファクタリング |
| `削除` | コード・ファイルの削除 |
| `設定` | 設定ファイルの変更 |
| `文書` | ドキュメントの変更 |

```
# 例
追加: 絞り値の分布ヒストグラムを実装
修正: EXIF読み取り時にクラッシュする問題を修正
変更: 写真リポジトリをasync/awaitに移行
```

---

## 8. 開発フェーズ

| フェーズ | 内容 |
|----------|------|
| Phase 1 | フォルダ読み込み → EXIF取得 → 写真グリッド表示 |
| Phase 2 | お気に入り機能・メモ機能・SwiftData永続化 |
| Phase 3 | 画像ビューア（フルスクリーン表示・キーボードナビゲーション・RAWプレビュー） |
| Phase 4 | スライドショー・基本編集（回転・トリミング）※非破壊 |
| Phase 5 | Swift Charts による設定分布グラフ（絞り・SS・ISO） |
| Phase 6 | カメラ別比較・お気に入りvs全体の分析ビュー |
| Phase 7 | ネットワークドライブ対応（段階的ロード・UIフリーズ防止） |
| Phase 8 | 外部アプリ連携（Capture One 等・アダプター実装） |
| Phase 9 | リキッドグラスUI対応・磨き込み |

> **iCloud写真ライブラリ連携は採用しない。** PhotoKit の macOS サンドボックス制約・App Store エンタイトルメント要件・RAWオリジナル取得の不安定さを考慮し、スコープ外とする。iCloud Drive 上のフォルダは通常のフォルダとして読み込み可能。

---

## 9. 外部アプリ連携設計方針

### 9.1 基本方針：アダプターパターンで将来拡張に備える

連携方式（AppleScript / XPC / URLスキーム等）は将来決定するため、現時点では**インターフェースのみ定義**し、実装を差し替えられる構造にする。

```swift
// 外部連携プロトコル.swift
// 連携方式に依存しない抽象インターフェース
protocol 外部アプリ連携プロトコル {
    var アプリ名: String { get }
    var 利用可能: Bool { get }

    /// 指定した写真を外部アプリで開く
    func 写真を開く(_ 写真: 写真) async throws

    /// 外部アプリから選択中の写真URLを取得する
    func 選択中の写真URLを取得する() async throws -> [URL]
}
```

```swift
// アダプター/CaptureOneアダプター.swift（将来実装）
struct CaptureOneアダプター: 外部アプリ連携プロトコル {
    var アプリ名: String { "Capture One" }
    var 利用可能: Bool { /* バンドルIDでインストール確認 */ }

    func 写真を開く(_ 写真: 写真) async throws {
        // AppleScript / URLスキームなど、決定した方式で実装
    }

    func 選択中の写真URLを取得する() async throws -> [URL] {
        // 同上
    }
}
```

### 9.2 連携方式の候補と選定基準

将来の実装時に以下を基準に選定する：

| 方式 | 向いているケース | 制約 |
|------|-----------------|------|
| AppleScript / JXA | アプリがScriptingに対応している | 相手アプリ依存 |
| URLスキーム | 軽量な起動・ファイル渡し | 双方向通信が難しい |
| XPC Services | セキュアなプロセス間通信 | 実装コストが高い |
| ファイル監視（FSEvents） | フォルダ経由の疎結合連携 | リアルタイム性に限界 |

---

## 10. ネットワークドライブ対応・画像ロード方針

### 10.1 段階的ロード戦略

ネットワーク遅延によるUIフリーズを防ぐため、**サムネイル先行表示 → EXIF遅延取得**の2段階ロードを採用する。

```
フォルダ読み込み開始
  │
  ├─ Step 1: ファイル一覧のみ即時取得（URLだけ）→ グリッドに空セルを表示
  │
  ├─ Step 2: AsyncStream でサムネイルをストリーミング取得
  │           → 取得できたセルから順次表示（プレースホルダー → サムネイル）
  │
  └─ Step 3: お気に入りや分析に必要な写真のEXIFのみ遅延取得
```

### 10.2 実装指針

```swift
// 画像ローダー.swift
actor 画像ローダー {
    // メモリキャッシュ（NSCache で自動解放）
    private let サムネイルキャッシュ = NSCache<NSURL, NSImage>()

    func サムネイルを取得する(url: URL) async -> NSImage? {
        // キャッシュヒット → 即返却
        if let キャッシュ済み = サムネイルキャッシュ.object(forKey: url as NSURL) {
            return キャッシュ済み
        }
        // ネットワーク/ローカル問わずバックグラウンドで取得
        return await Task.detached(priority: .utility) {
            // ImageIO で縮小サムネイルのみ読み込み（フルサイズ読み込みを避ける）
            let オプション = [kCGImageSourceThumbnailMaxPixelSize: 256,
                             kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary
            guard let ソース = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let CGサムネイル = CGImageSourceCreateThumbnailAtIndex(ソース, 0, オプション)
            else { return nil }
            return NSImage(cgImage: CGサムネイル, size: .zero)
        }.value
    }
}
```

### 10.3 UIフリーズ防止のルール

- ネットワークI/Oは必ず `Task.detached(priority: .utility)` でバックグラウンド実行する
- メインスレッドでのファイルアクセスは禁止（`@MainActor` 内で `FileManager` を呼ばない）
- `NSCache` を使い、メモリ逼迫時は自動解放させる（手動での全キャッシュクリアは行わない）
- 読み込み中はプレースホルダー（グレーの矩形）を表示し、完了後にアニメーションで差し替える

---

## 11. 画像ビューア機能の設計方針

### 11.1 表示モードの拡張可能設計

将来的に表示モードが増えることを前提とし、**モードをプロトコルで抽象化**する。新モードの追加はプロトコルに準拠した型を1つ追加するだけで済み、ツールバーや設定画面はモード一覧を動的に読み取るため既存コードの変更が不要になる。

```swift
// 表示モードプロトコル.swift
// 全表示モードが準拠すべきインターフェース
protocol 表示モードプロトコル: Identifiable {
    var id: String { get }
    var 表示名: String { get }          // ツールバー・設定画面に表示するラベル
    var アイコン名: String { get }       // SF Symbols のシンボル名
    var キーボードショートカット: KeyEquivalent? { get }

    // このモードのルートビューを生成する
    @ViewBuilder
    func ビューを生成する(写真一覧: [写真], 選択中: Binding<写真?>) -> AnyView
}
```

```swift
// 表示モードレジストリ.swift
// モードの登録・管理を一元化する。新モードはここに1行追加するだけ
final class 表示モードレジストリ {
    static let shared = 表示モードレジストリ()

    private(set) var 登録済みモード: [any 表示モードプロトコル] = [
        サイドバーモード(),
        フルスクリーンモード(),
        スライドショーモード(),
        // 将来追加例:
        // グリッドモード(),
        // 比較モード(),
        // マップモード(),
    ]

    // 新モードを動的に追加
    func 登録する(_ モード: any 表示モードプロトコル) {
        登録済みモード.append(モード)
    }
}
```

```swift
// ツールバービューモデル.swift — モード一覧を動的に取得（ハードコードしない）
@Observable
final class ツールバービューモデル {
    var 利用可能なモード: [any 表示モードプロトコル] {
        表示モードレジストリ.shared.登録済みモード
    }
    var 現在のモードID: String = サイドバーモード().id
}
```

### 11.2 現在実装する表示モード（初期3種）

| モード | ID | 実装方針 | ショートカット |
|--------|----|----------|--------------|
| サイドバー | `sidebar` | `NavigationSplitView`（3カラム：写真一覧 / ビューア / EXIFパネル） | デフォルト |
| フルスクリーン | `fullscreen` | `NSWindow.toggleFullScreen` + 黒背景オーバーレイ | `⌘⌃F` |
| スライドショー | `slideshow` | フルスクリーン + `AsyncStream` タイマー駆動 | `Space` で再生/停止 |

将来追加が想定されるモード（スコープ外・参考）：グリッド表示、2枚比較、地図表示（GPS連動）、顔検出モードなど。

### 11.3 設定画面でのモード管理

- 設定画面の「表示モード」セクションで有効/無効を切り替えられる
- ツールバーには有効化されたモードのみ表示する（`UserDefaults` で永続化）
- デフォルトで起動時に開くモードも設定から変更できる

```swift
// 表示モード設定.swift
struct 表示モード設定 {
    // 有効なモードIDセット（UserDefaults に保存）
    var 有効なモードID: Set<String> = ["sidebar", "fullscreen", "slideshow"]
    // 起動時のデフォルトモード
    var デフォルトモードID: String = "sidebar"
}
```

### 11.4 その他の機能と実装アプローチ

| 機能 | 実装方針 |
|------|----------|
| サイドバー開閉トグル | `NavigationSplitView.columnVisibility` で制御（`⌘[`） |
| EXIFパネル開閉トグル | サイドバーモード時のみ表示（`⌘⌥E`） |
| キーボードナビゲーション | `←` / `→` で前後移動、`Esc` でサイドバーモードに戻る |
| RAWプレビュー | ImageIO の `CGImageSourceCreateImageAtIndex` で現像なし表示（Core Image は使わない） |
| 基本編集（回転） | `CGImagePropertyOrientation` をメタデータに書き込む（非破壊） |
| 基本編集（トリミング） | トリミング範囲を SwiftData に保存し、表示時のみ適用（元ファイルを変更しない） |

### 11.5 非破壊編集の原則

**元ファイルは絶対に上書きしない。** 編集情報はすべて SwiftData 側に保持し、表示・エクスポート時にのみ適用する。

```swift
@Model
final class 編集情報 {
    var 写真ID: UUID
    var 回転角度: Int           // 0 / 90 / 180 / 270
    var トリミング領域: CGRect?  // nil = トリミングなし（正規化座標 0.0〜1.0）
    var 作成日時: Date
}
```

### 11.6 RAWプレビューの注意点

- RAW現像（露出・色温度の調整）はスコープ外とする。あくまで「撮って出し確認」用のプレビューに留める
- Nikon NEF / Leica DNG は ImageIO でサポートされているが、機種によって対応状況が異なるため、読み込み失敗時は適切なエラーメッセージを表示する
- フルサイズRAWのデコードは重いため、ビューアで表示する際も最大解像度を画面サイズに合わせて制限する（`kCGImageSourceSubsampleFactor` を活用）

---

## 12. フォルダ指定・履歴管理の設計方針

### 12.1 基本方針

- **1度に開けるフォルダは1つのみ**。複数フォルダの同時表示はスコープ外とする
- フォルダの追加方法は**ドラッグ＆ドロップ**と**Open Panel（ファイルピッカー）**の両方に対応する
- 開いたフォルダの履歴を保持し、**「最近開いたフォルダ」として再アクセスできる**（macOS標準の `NSDocumentController` の `Open Recent` に相当）

### 12.2 フォルダの開き方

```
① ドラッグ＆ドロップ
   Finder からウィンドウ（または Dock アイコン）にフォルダをドロップ
   → NSApplicationDelegate.application(_:open:) で受け取る

② ファイルピッカー（Open Panel）
   メニューバー「ファイル > フォルダを開く...」または ⌘O
   → NSOpenPanel（canChooseDirectories: true, canChooseFiles: false）
```

### 12.3 履歴管理

- 履歴は **最大10件** を上限とし、SwiftData に `フォルダ履歴` モデルとして保存する
- 同じフォルダを再度開いた場合は履歴の先頭に移動する（重複排除）
- メニューバー「ファイル > 最近開いたフォルダ」のサブメニューに一覧表示する
- 履歴はクリア可能にする（「履歴を消去」メニュー項目）

```swift
@Model
final class フォルダ履歴 {
    var url: URL
    var 最終アクセス日時: Date
    var 表示名: String        // フォルダ名（フルパスではなく末尾のコンポーネント）

    init(url: URL) {
        self.url = url
        self.最終アクセス日時 = Date()
        self.表示名 = url.lastPathComponent
    }
}
```

### 12.4 サンドボックスとセキュリティスコープ

macOS のサンドボックス環境では、ユーザーが選んだフォルダへのアクセス権を**セキュリティスコープ付きブックマーク**として永続化する必要がある。履歴からフォルダを再度開く際にも、ブックマークを使って権限を復元する。

```swift
// フォルダ選択時：ブックマークを保存
let ブックマーク = try url.bookmarkData(
    options: .withSecurityScope,
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)
// SwiftData の フォルダ履歴 に Data として保存

// 再アクセス時：ブックマークから URL を復元
var 失効済み = false
let 復元URL = try URL(
    resolvingBookmarkData: ブックマーク,
    options: .withSecurityScope,
    relativeTo: nil,
    bookmarkDataIsStale: &失効済み
)
復元URL.startAccessingSecurityScopedResource()
defer { 復元URL.stopAccessingSecurityScopedResource() }
```

> セキュリティスコープブックマークを実装しないと、アプリ再起動後に履歴のフォルダへアクセスできなくなる。必ずセットで実装すること。

---

## 13. Sigma fp L カラーモード再現

### 13.1 調査結果（FPL00857.DNG 実測）

Sigma fp L が出力する DNG を実際に解析した結果、以下が確認できた。

| 確認項目 | 結果 |
|---------|------|
| カラーモード名の記録 | MakerNote `PictureMode` タグに文字列で記録される（例: `PowderBlue`） |
| 色変換データの埋め込み | DNG標準タグ（`ProfileHueSatMapData1/2`・`ProfileToneCurve`・`ColorMatrix1/2`）に含まれる |
| カラーモードの判別 | ExifTool / ImageIOで確実に取得可能 |

**結論：Sigma fp L の DNG には、カラーモードの判別情報と色変換データの両方が埋め込まれており、正確な色再現が原理上可能。**

### 13.2 対応カラーモード一覧

Sigma fp L の全16モード。`PictureMode` タグの文字列値と表示名の対応：

| PictureMode 文字列 | 表示名 |
|-------------------|--------|
| `Standard` | スタンダード |
| `Vivid` | ビビッド |
| `Neutral` | ニュートラル |
| `Portrait` | ポートレート |
| `Landscape` | ランドスケープ |
| `Cinema` | シネマ |
| `WarmGold` | ウォームゴールド |
| `TealAndOrange` | ティール＆オレンジ |
| `SunsetRed` | サンセットレッド |
| `ForestGreen` | フォレストグリーン |
| `PowderBlue` | パウダーブルー |
| `FOVClassicBlue` | FOVクラシックブルー |
| `FOVClassicYellow` | FOVクラシックイエロー |
| `Duotone` | デュオトーン |
| `Monochrome` | モノクローム |
| `Off` | オフ（カラーモードなし） |

### 13.3 実装方針

**フェーズ1：ImageIO の埋め込みプロファイルを信頼する**

ImageIOが DNG 内の `ProfileHueSatMapData` と `ProfileToneCurve` を自動適用するため、追加の色変換実装なしで再現できる可能性が高い。まずこれで試す。

```swift
// EXIFサービス.swift — Sigma MakerNote からカラーモードを取得
func カラーモードを取得する(source: CGImageSource) -> String? {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
          let makerNote = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
    else { return nil }

    // Sigma MakerNote の PictureMode タグ (0x003d) を読む
    // ImageIO 経由では直接取れないため、ExifTool相当のバイト解析が必要
    // → 代替: ExifTool をバンドルするか、libexif を使う
    return nil // Phase 2 で実装
}
```

> MakerNoteの直接読み取りは ImageIO 単体では困難なため、**Phase 2 でアプローチを確定する**。

**フェーズ2：MakerNote 取得方法の確定（選択肢）**

| 方法 | メリット | デメリット |
|------|---------|-----------|
| A. ExifTool をバンドル | 確実・全カメラ対応 | バイナリ配布・サイズ増加 |
| B. libexif / exiv2 をSPMで導入 | ネイティブ統合 | メンテナンスコスト |
| C. DNGのバイナリを直接パース | 依存なし | 実装コスト高・壊れやすい |
| D. RAW+JPEG同時記録でJPEGから取得 | 確実・実装簡単 | ユーザーの撮影設定に依存 |

Phase 2 の開始時に方法を決定し、この規約書を更新する。

**フェーズ3：Core Image フォールバック（ImageIOで色が出ない場合）**

ImageIOが埋め込みプロファイルを正しく適用しなかった場合、`ProfileHueSatMapData` を手動で読み取り Core Image フィルタに変換する。

```swift
// 色変換の適用（フォールバック）
func カラーモードフィルタを生成する(
    hueSatData: Data,
    toneCurveData: Data
) -> CIFilter? {
    // ProfileHueSatMapData → CIHueSaturationValueGradient
    // ProfileToneCurve    → CIToneCurve
    // 実装は Phase 3 で確定
    return nil
}
```

### 13.4 EXIFパネルへの表示

カラーモードが取得できた場合、EXIFパネルに表示する。`Off` または `nil` の場合は表示しない。

```swift
// EXIFパネルの表示項目に追加
if let モード = 写真.カラーモード, モード != "Off" {
    EXIF行ビュー(キー: "カラーモード", 値: モード)
}
```

### 13.5 CLAUDE.md との対応

`CLAUDE.md` の「対応画像フォーマット」と「EXIFサービス」の実装時は、Sigma DNG の特殊処理（カラーモード取得）を必ず考慮すること。

---

*このドキュメントはプロジェクトの進行に合わせて随時更新する。*
