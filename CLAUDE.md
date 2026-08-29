# ShootLog — CLAUDE.md

ShootLogの実装・保守時に参照する開発規約。詳細な背景と設計判断は
`Docs/ShootLog_プロジェクト規約書.md`、UIの参考資料は `Docs/UI_モックアップ.html` を参照する。

## プロジェクト概要

macOS向けの写真管理・閲覧アプリ。ユーザーが選択したフォルダの写真を読み込み、EXIF情報の表示、撮影設定の分析、複数の閲覧モード、非破壊編集を提供する。

### 現在の対応環境

| 項目 | 値 |
|------|----|
| 対象OS | macOS 14 Sonoma以降 |
| Swift | 6.0 |
| UI | SwiftUI / AppKit |
| 永続化 | SwiftData |
| Bundle ID | `com.shootlog.app` |
| Sandbox | 有効 |
| プロジェクト設定 | `project.yml`（XcodeGen） |

### 必須Entitlements

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
```

## 現在のディレクトリ構成

```text
ShootLog/
├── Core/
│   ├── Integration/             # 外部アプリ連携プロトコル・アダプター
│   ├── Services/                # EXIF・画像ロード・写真URLスキャン
│   └── ShootLogError.swift
├── Models/                      # SwiftDataモデル
├── ViewModels/                  # @Observableの状態管理
├── Views/                       # SwiftUI画面・共通UI
├── Resources/                   # Localizable.xcstrings（日本語・英語）
├── Assets.xcassets/
├── Info.plist
└── ShootLog.entitlements
```

新しいコードは、現在の責務に最も近い既存ディレクトリへ追加する。現在の構成を維持し、無関係な大規模移動は行わない。

言語・識別子ルール、Observation、非同期処理、エラー処理、UIの規約は `.claude/rules/swift-style.md` を参照。

## アーキテクチャ

MVVMを採用し、レイヤーの責務を分離する。

```text
View（SwiftUI）        — レイアウトと表示。状態変更はViewModelへ委譲
  └─ ViewModel         — @Observable + @MainActor。画面状態と操作を管理
       └─ Model        — SwiftData @Modelエンティティ
            └─ Service — EXIF取得、ファイルI/O、画像キャッシュ
```

- ViewModelはView型を直接生成しない。
- 表示モードの切り替えは `ContentView` が `currentModeID` を見て行う。
- `ViewModeRegistry` はモードとモード用ViewModelの登録を管理する。

## ローカライズ

日本語（開発言語）と英語に対応する。翻訳はすべて `ShootLog/Resources/Localizable.xcstrings`（String Catalog）で管理し、
言語の切り替えはmacOSのシステム設定「言語と地域」のアプリ個別言語に委ねる。アプリ内に言語切替UIは持たない。

### 文字列の書き方

UIに表示する文字列は、日本語をコードに直接書かず、ASCIIのシンボリックキーで書く。

| 層 | 使用API | 例 |
|----|---------|-----|
| SwiftUI View 内のリテラル | そのまま記述（`LocalizedStringKey`へ自動変換） | `Text("analysis.title")` |
| ViewModel / Model / Service | `String(localized:)` | `String(localized: "photo.tag.light")` |
| ViewからViewModelへ渡す表示名 | `LocalizedStringResource` | `var displayName: LocalizedStringResource` |

キーは `<スコープ>.<要素>[.<用途>]` 形式とし、`common.` `error.` `toolbar.` `menu.` `exif.` `analysis.` `settings.`
`empty.` `viewMode.` `photo.tag.` `a11y.` `viewer.` `inspector.` `openPanel.` `sidebar.` `editor.` `externalApp.`
`integration.` `slideshow.` `toast.` `crop.` `upscale.` `develop.` のいずれかで始める。`a11y.` は表示ラベルをそのまま流用できない場合にだけ新設する。

補間を含む文字列は位置指定プレースホルダ（`%1$@` 形式）を使い、語順が言語で変わってもよいようにする。
「〜枚」「〜件」のような数を伴う表現は、String Catalog の複数形（plural variation）を必ず設定する。

### ローカライズしないもの

- `ViewModeProtocol.id`、`SuccessTagCategory` の raw value、`AppSettingsKeys` のキーなど永続化される識別子
- SF Symbols 名、バンドルID、ファイル拡張子
- `EXIFService` の `dateFormat`（EXIF規格固定。`locale` は `en_US_POSIX` に固定する）
- `f/`、`mm`、`ISO`、`s` などの国際共通の単位表記（数値部のロケール対応のみ行う）
- 開発者向けの `fatalError` メッセージ

### 表示文言と識別子の分離

列挙型の raw value に表示文言を持たせない。raw value は安定したASCIIとし、表示名は `displayName` に分ける
（`SuccessTagCategory`、`AnalysisViewModel.AnalysisPage`、`AnalysisViewModel.ChartSeries` が参考例）。
特にチャートの系列名は凡例と `chartForegroundStyleScale` の照合キーを兼ねるため、生の文字列ではなく必ず
`ChartSeries.displayName` を経由する。

### 検証

コードが使っているキーとString Catalogの定義が一致しているかは、`.stringsdata` を出力してから突き合わせる。

```text
xcodebuild -project ShootLog.xcodeproj -scheme ShootLog -sdk macosx build CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES
```

英語表示の確認はアプリを次の引数付きで起動する。

```text
ShootLog.app/Contents/MacOS/ShootLog -AppleLanguages "(en)"
```

## 非同期処理とファイルI/O

- `@MainActor`上で同期的なファイル読み込みを行わない。
- セルが画面外へ移動した場合など、キャンセルを考慮する。
- 基本原則（async/await、Combine/DispatchQueue不使用など）は `.claude/rules/swift-style.md` を参照。

## 対応画像とフォルダ読み込み

対応拡張子は `.nef` `.dng` `.arw` `.cr3` `.raf` `.jpg` `.jpeg` `.heic` `.tiff` `.png`。拡張子は大文字小文字を区別しない。

- 対象は選択フォルダの直下のみ。サブフォルダは再帰読み込みしない。
- 非対応拡張子や隠しファイルはスキップする。
- ファイル一覧は `PhotoRepository.scanImageURLs(in:)` で取得し、作成日時順に並べる。
- フォルダはOpen PanelまたはFinderからのドラッグ＆ドロップで開く。
- 同時に表示するフォルダは1つだけ。

## 画像ロード戦略

現行実装は以下の順で読み込む。

1. ファイルURL一覧を取得し、グリッドにプレースホルダーを表示する。
2. `ImageLoader` が埋め込みプレビューを優先してサムネイルを非同期取得する。
3. 埋め込みプレビューが小さすぎる場合は、ImageIOで最大768pxのサムネイルを生成する。
4. 写真選択時または分析画面表示時に、必要な写真のEXIFを遅延取得する。

キャッシュとネットワーク対応:

- メモリキャッシュは `NSCache<NSURL, NSImage>` を使用する。
- ディスクキャッシュは `~/Library/Caches/com.shootlog.app/thumbnails-v4/` に保存する。
- ネットワークボリュームではサムネイル同時取得数を4件に制限する。
- キャッシュ待機中のタスクがキャンセルされた場合は待機列から取り除く。
- フルサイズ画像はビューア用に別キャッシュへ保存し、必要なときだけデコードする。
- キャッシュを通常操作で手動全消去しない。

## フォルダアクセスと履歴

ユーザーが選択したフォルダは、選択時にセキュリティスコープブックマークを作成して `FolderHistory` に保存する。履歴から開く際はブックマークを復元し、アクセス終了時にスコープを解放する。

- 履歴は最近アクセスした順に最大10件保持する。
- 同じフォルダを開いた場合は重複させず先頭へ移動する。
- ブックマークがstaleの場合は更新して保存する。
- アクセス拒否・ブックマーク復元失敗は `ShootLogError` として画面に通知する。

## 現在実装されている機能

- お気に入りの登録・解除、Favorites Only絞り込み
- 写真メモの保存
- ImageIOによるカメラ、レンズ、絞り、シャッター速度、ISO、焦点距離、撮影日時のEXIF取得
- サイドバー、フルスクリーン、スライドショーの3表示モード
- 左サイドバーと右EXIFパネルの表示切り替え
- 回転・トリミング情報のSwiftData保存（元ファイルは変更しない）
- 絞り、シャッター速度、ISOなどの分析画面
- Capture One、Lightroom、Photoshop、Affinity Photo、Preview、Finder向けアダプターによる写真起動
- RAW現像編集（サイドバーモードの右インスペクタ「編集」タブ）: 露出・コントラスト・ハイライト/シャドウ・白黒レベル・色温度・自然な彩度/彩度・トーンカーブ（RGB/チャンネル別）・カラー別HSL・シャープ・ノイズ低減。Core Image ベース、非破壊（`DevelopSettings` に保存）
- 現像結果のJPEG/TIFF書き出し（調整・回転・トリミングを焼き込み、原本は保護）

## SwiftDataモデル

主なモデルは `Photo`、`EditInfo`、`DevelopSettings`、`FolderHistory`。

- `Photo`: ファイルURL、撮影日時、EXIF、`isFavorite`、`note`、`exifFetchedAt`
- `EditInfo`: 写真ID、回転角度、正規化されたトリミング矩形、作成日時
- `DevelopSettings`: 写真ID、現像調整値（`DevelopParameters` の JSON blob）、スキーマ版、更新日時。`EditInfo` とは独立
- `FolderHistory`: フォルダURL、セキュリティブックマーク、最終アクセス日時、表示名

元画像は上書きしない。編集情報はSwiftDataに保持し、表示時に適用する。

## EXIFとSigma fp L

EXIF読み取りは `EXIFService` のactorでImageIOを使って行う。Sigma fp LのPictureModeは、ImageIOがMakerNoteを辞書として返す場合の読み取りと、既知のモード名をMakerNoteのバイナリから検索する暫定処理を行う。

Sigma fp Lのカラーモード検出は実機サンプルで十分に検証されていない。取得できない場合は `nil` とし、検出を完成機能として扱わない。ExifTool、libexifなどの外部依存は現時点で導入しない。

## UIルール

- 操作可能な要素には、用途が伝わる `.accessibilityLabel` を付ける。
- 写真ビューア（フルスクリーン・スライドショー・サイドバーモードの右ペイン）の背景は `Color.viewerCanvas` を使い、システム外観に追従させる。ライトでは中間グレー、ダークでは黒になる。ライトで純白を使わないのは、写真の白飛び・ハイライトを目視判定できなくなるため。
- macOS 26以降のLiquid Glassは `#available(macOS 26, *)` で分岐し、macOS 14向けの代替UIも用意する。両分岐で同じ意味の配色になるようにする（一方だけを固定色にしない）。
- UIのレイアウトやインタラクションは `Docs/UI_モックアップ.html` とApple HIGを参照する。

### 色の扱い

Viewに色リテラルを直書きせず、以下のいずれかを使う。

| 種類 | 使い方 |
|------|--------|
| システムのセマンティックカラー | `.primary` `.secondary` `.quaternary` `.tint` `Color.accentColor` |
| アプリ固有の色 | `ShootLog/Assets.xcassets/Colors/` にColor Setを追加し、Xcodeが自動生成するシンボル（`Color.viewerCanvas` 等）で参照する |

Color Setはライト・ダークの2スロットを必ず定義する。Xcodeが Asset Symbol を自動生成するため、
`DesignSystem.swift` に手書きのアクセサを定義してはならない（`invalid redeclaration` でビルドが通らない）。

Material・Liquid Glassはシステム外観に追従するため、その上に載せる前景色を固定色にしない。
またこれらは機能層（ツールバー・フローティングコントロール・HUD）にのみ使い、コンテンツ層
（EXIFカード・履歴行などのリスト項目）には `.quaternary` 等の塗りで階層を付ける。

チャートのデータ系列色（`AnalysisView` の `chartForegroundStyleScale`）は系列識別が目的の
意図的な固定色であり、この規約の対象外とする。

## エラー処理

- フォルダ操作などユーザー操作の直接結果はAlertで表示する。
- サムネイルなどバックグラウンド処理の失敗は、処理全体を止めず適切なインライン通知を検討する。
- 一時的な成功通知はToastで表示し、現在のToastは約2秒で消去する。

## 開発状況

### 実装済み

フォルダ読み込み、セキュリティスコープ付き履歴、基本EXIF取得、サムネイル/高解像度画像ロード、SwiftData永続化、お気に入り・メモ、3表示モード、非破壊回転・トリミング、分析画面、外部アプリ起動連携、RAW現像編集（Core Image ベース）、現像結果のJPEG/TIFF書き出し。

### 制限付き・検証継続中

- Sigma fp LのPictureMode検出は暫定実装。
- サムネイル/一覧表示は引き続きImageIOの対応範囲でプレビューする（現像は「編集」タブ選択時のみ）。
- 現像編集: カラー別HSLはCore Imageに単一フィルタが無いためCPU生成の3D LUT（`CIColorCube`）による近似。出力カラースペースはsRGB固定。`CIRAWFilter`のRAW固有現像パラメータ（exposure等のオフセット写像）はv1では未適用でベースデコード専用。トリミングのライブプレビューは未対応で書き出し時にのみ矩形を適用する。RAW実ファイルでのデコード経路は実機サンプル不足のため継続検証中。詳細は `Docs/ShootLog_設計書.md` 6章。
- ネットワークドライブの性能最適化は継続改善する。
- 全操作要素のアクセシビリティ、エラー通知の網羅性、macOS 26のLiquid Glass対応は継続監査する。

### 未着手・スコープ外

- ローカル調整（マスク・レイヤー）、レンズ補正、Display P3出力、編集プリセット
- 複数フォルダの同時表示
- iCloud写真ライブラリ連携
- 外部アプリとの双方向同期
- GPS地図表示、顔検出、比較ビュー

## Gitコミットルール

形式は `種別: 変更の概要` とし、日本語で記述する。

使用する種別は `追加`、`修正`、`変更`、`削除`、`設定`、`文書`。

```text
追加: サムネイルグリッド表示を実装
修正: EXIF読み取り時のクラッシュを修正
変更: ImageLoaderのキャッシュ戦略を更新
文書: 現行の実装状況をREADMEに反映
```

各機能は単体で動作確認できる状態にしてからコミットする。既存のユーザー変更を含むファイルを、無関係な目的で巻き戻さない。

## 表示モードの拡張

新しい表示モードは `ViewModeProtocol` に準拠する型を作り、`ViewModeRegistry` に登録する。`ViewModeProtocol` はView生成メソッドを持たない。ViewModelがView型を参照しないよう、モード切り替えとView生成は `ContentView` 側で行う。

```swift
protocol ViewModeProtocol: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }
    var keyboardShortcut: KeyEquivalent? { get }
}
```

## 検証

Xcodeプロジェクトのビルド確認には次を使用する。

```text
xcodebuild -project ShootLog.xcodeproj -scheme ShootLog -sdk macosx build CODE_SIGNING_ALLOWED=NO
```

ドキュメントの記載を変更した場合も、`project.yml`、主要Service、ViewModel、Modelの実装と内容を照合する。
