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
<key>com.apple.security.personal-information.photos-library</key><true/>
```

`personal-information.photos-library` はiCloud写真ライブラリ統合（`PhotosLibraryPermissionService`）向け。Info.plistの `NSPhotoLibraryUsageDescription` とセットで必要（無いと権限ダイアログ自体が出ず `.denied` になる）。

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
`integration.` `slideshow.` `toast.` `crop.` `upscale.` `develop.` `photosLibrary.` のいずれかで始める。`a11y.` は表示ラベルをそのまま流用できない場合にだけ新設する。

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

## iCloud写真ライブラリの読み込み

macOS純正「写真」Appと同様に、Photosライブラリの写真を読み込んで閲覧できる（フォルダ読み込みとは別導線、詳細は `.omc/plans/icloud-photo-library-integration.md`）。

- 空状態画面の「写真ライブラリを開く」から`PhotosLibraryPermissionService`が権限確認・リクエストを行う。フルアクセス以外（限定・拒否・未決定）は案内Alertのみで機能を提供しない。
- フルアクセス時、`PhotosLibraryRepository.fetchAssets()`が画像アセット（`.image`のみ、動画は対象外）を撮影日時昇順で取得し、`ContentViewModel.currentPhotoSource`（`.folder(URL)` / `.photosLibrary`）で「写真ソースが開かれているか」の判定をフォルダ機能と共通化する。
- 重複防止キーは`Photo.phAssetLocalIdentifier`（フォルダ写真は`nil`）。
- **エクスポートキャッシュ方式**を採用: `Photo.fileURL`は`PhotosLibraryAssetExporter.defaultDirectory`（`~/Library/Caches/com.shootlog.app/icloud-import-v2/`）配下の、サニタイズしたlocalIdentifierをファイル名にしたプレースホルダーパス。実ファイルは未生成の状態で`Photo`が作られ、写真選択時（`PhotoImageViewModel.load` / `loadEXIFIfNeeded`）に`PhotosLibraryAssetExporter.ensureExported(localIdentifier:fileURL:)`がPHAssetから高品質JPEGをこのパスへ書き込む（同一アセットへの同時要求はin-flight Taskで1本化）。これにより`ImageLoader`/`PreviewCacheStore`/`PhotoImageViewModel`/`EXIFService`/お気に入り・メモ・分析画面をほぼ無改修で再利用できる。
- グリッドのサムネイルは`ImageLoader`のディスクキャッシュを経由せず、`PhotosLibraryThumbnailProvider`（PHImageManager直結の軽量パス）を使う専用経路（`PhotoThumbnailViewModel.load(photo:)`が`phAssetLocalIdentifier`の有無で分岐）。
- `icloud-import-v2/`は上限2GiB（`PhotosLibraryAssetExporter.defaultMaxDiskBytes`）でmtime昇順eviction。起動時`warmUp()`とエクスポート成功のたびに整理し、設定画面「ディスクキャッシュを削除」の対象にも含まれる。
- 分析画面はエクスポート未了（EXIF未取得）のiCloud写真を強制エクスポートしない。大量写真の一括ネットワークダウンロードを避けるため、既存の欠損データ処理（EXIFがnilのまま集計対象に含まれる）に委ねる。
- RAW現像編集・書き出し・超解像連携、限定アクセス時のブラウジングUIはスコープ外。

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
- キャッシュを通常操作で手動全消去しない。設定画面「ディスクキャッシュを削除」はサムネイル・プレビュープロキシ・現像ベースの3キャッシュをまとめて消す。

### プレビュープロキシ層（Capture One 参考、RAW読み込み高速化）

ビューア高解像度表示と現像編集の体感速度を上げるため、固定解像度のプレビュープロキシを永続キャッシュする。

- `PreviewCacheStore`（`Sendable`）: 長辺 `previewProxyLongEdge`（既定3200px、設定可）のプロキシを HEIC 品質0.9（失敗時 JPEG）で `~/Library/Caches/com.shootlog.app/previews-v1/` へ、CGImage を `NSCache` へ。ファイル名は `sha256(url + mtime + size + proxyLongEdge)` で原本差し替え・解像度変更時に自動失効。上限 `previewCacheMaxBytes`（既定4GiB）を超えたらキャッシュファイルの mtime 昇順で削除。生成は埋め込みプレビュー優先、不足時のみ元画像からダウンサンプル。内部 `DecodeThrottle`（`max(2, コア数)`）でビューアの対話要求とバックグラウンド生成が同一デコード枠を共有する。
- `ImageLoader.proxyImage(for:)` がラッパ。`PhotoImageViewModel.load` は サムネ(768) → プロキシ(3200) → 表示領域がプロキシ解像度を明確に超える場合のみ `highResImage` を追加要求、の段階表示。ズーム100%時のみ従来のフルデコード。
- `PreviewGenerator`（actor）: フォルダ読み込み時に全写真のプロキシを `.utility` でバックグラウンド生成。選択インデックス近傍を優先、`max(2, コア数-2)` ワーカー、フォルダ切替でキャンセル（セキュリティスコープ解放前に停止）。進捗はサイドバー下部に「プレビュー生成中 N枚」。
- `HighResPrefetcher`: 選択写真の前後を先読み。枚数はボリューム種別で決める（ローカル ±3 / ネットワーク ±1）。呼び先は `proxyImage`。
- 現像 Stage A の中立ベース（`rawParamsHash == 0`）は PNG ロスレスで `~/Library/Caches/com.shootlog.app/develop-base-v1/`（上限 `developBaseCacheMaxBytes`、既定2GiB）へも永続化。再訪・再起動で `CIRAWFilter`/ImageIO デコードをスキップ。ロッシー圧縮は後段トーンカーブでのブロックノイズ増幅を避けるため使わない。書き出し（`renderFull`）は常にフル解像度 `CIRAWFilter` で、この層を通らない。
- ディスク入出力（原子的書き込み・容量 eviction・中断 temp 掃除）は `ImageFileCache` に集約し `PreviewCacheStore` と develop-base で共有する。起動時に `PreviewCacheStore.warmUp()` / `ImageDevelopmentEngine.warmUpCaches()` がディレクトリ用意と eviction を行う。
- **RAW の現像ベースにビューアプロキシ（＝カメラ埋め込み JPEG）は流用しない。** プロキシはカメラのピクチャースタイルが焼き込まれており、`CIRAWFilter` 中立解釈の書き出しと見えが食い違って WYSIWYG が破れるため。撮影時ホワイトバランスは `asShotNeutral` のメモリキャッシュ＋`Photo` への永続化で写真選択ごとの `CIRAWFilter` 生成を避ける。

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
- RAW現像編集（サイドバーモードの右インスペクタ「編集」タブ）: 露出・コントラスト・ハイライト/シャドウ・白黒レベル・ホワイトバランス（色温度スライダー＋色かぶり、モードプリセット、As Shot 実測/推定ケルビン表示）・自然な彩度/彩度・トーンカーブ（RGB/チャンネル別）・カラー別HSL・4ホイールのトーン域マスク カラーグレーディング（Master/Shadow/Midtone/Highlight、`ColorWheelView`）・シャープ・ノイズ低減、RAWのレンズプロファイル補正トグル、非RAW/プロファイル無しRAW向けの手動レンズ補正（歪曲・周辺光量・色収差、`schemaVersion` 3）。Core Image ベース、非破壊（`DevelopSettings` に保存、`schemaVersion` 5）。RAWの露出・色温度・色かぶり・レンズ補正は`CIRAWFilter`側へ委譲（`RAWDevelopMapping`、schemaVersion 2）。撮影時ホワイトバランスは RAW が `CIRAWFilter` の as-shot 実測値、非RAW は EXIF/グレーワールド推定（`ImageDevelopmentEngine.asShotNeutral`）。プレビューは現像調整に加え回転・トリミングも焼き込んで書き出しと同じ構図で表示する
- 現像調整プリセット（`DevelopPreset` に保存、写真をまたいで適用）、調整のコピー＆ペースト、プリセット/ペースト適用の1段Undo。プリセット適用は「置き換え」に加え「現在の調整に加算」（相対適用、`DevelopParameters.applying(delta:)`）を選べる。加算系は加算＋クランプ、トーンカーブは関数合成、カラーグレーディングは成分ごと（Master/Shadow/Midtone/Highlight の hue/saturation/lightness）に加算＋クランプ、`lensCorrectionEnabled` は OR
- レンズ補正プロファイル（`LensCorrectionProfile` @Model、機種・レンズ・焦点距離→3補正量。`LensProfileStore.bestMatch` が完全一致→焦点距離補間→焦点距離非依存の順で検索）。v3では検索基盤とテストのみで、UI連携（自動適用・プロファイル作成）は未実装
- 現像結果のJPEG/TIFF書き出し（調整・回転・トリミングを焼き込み、原本は保護）。出力カラースペースはsRGB / Display P3を選択可。書き出し時に超解像を続けて適用する現像→超解像チェーンにも対応（回転は現像段で焼き込み済みのため超解像へは `rotation:0` を渡す）
- プレビュープロキシの永続キャッシュ（`PreviewCacheStore`、`previews-v1`）とフォルダ読み込み時のバックグラウンド生成（`PreviewGenerator`）、現像 Stage A 中立ベースの永続キャッシュ（`develop-base-v1`）。設定画面でプレビュー解像度（2560/3200/4096px）とキャッシュ上限（GB）を変更可。詳細は「画像ロード戦略 > プレビュープロキシ層」

## SwiftDataモデル

主なモデルは `Photo`、`EditInfo`、`DevelopSettings`、`DevelopPreset`、`LensCorrectionProfile`、`FolderHistory`。

- `Photo`: ファイルURL、撮影日時、EXIF、`isFavorite`、`note`、`exifFetchedAt`、撮影時ホワイトバランス（`asShotTemperatureKelvin` / `asShotTint` / `asShotWhiteBalanceIsEstimated` / `asShotWhiteBalanceFetchedAt`、いずれも optional・軽量マイグレーション。`loadEXIFIfNeeded` が EXIF と独立に取得・保存し、取得不能も `asShotWhiteBalanceFetchedAt` を立てて再試行を抑止する）
- `EditInfo`: 写真ID、回転角度、正規化されたトリミング矩形、作成日時
- `DevelopSettings`: 写真ID、現像調整値（`DevelopParameters` の JSON blob）、スキーマ版（新規は 5）、更新日時。`EditInfo` とは独立。`schemaVersion` 世代: 1=全て標準チェーン / 2=RAW露出・WBを`CIRAWFilter`委譲 / 3=手動レンズ補正 / 4=絶対Kelvin/Tintのホワイトバランス / 5=トーン域マスク カラーグレーディング。version 2〜4 は編集時に 5 へ自動バンプ（`setParameters`、追加値は中立既定で見た目不変）、version 1 は据え置き
- `DevelopSettings` の兄弟 `DevelopPreset`: 名前、現像調整値の JSON blob、スキーマ版、作成日時、並び順。特定の写真に紐付かないグローバルなプリセット
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
カラーグレーディングの色相環（`ColorWheelView`）とホワイトバランスのトラックグラデーション（`WhiteBalanceSection` の色温度＝青⇔黄、色かぶり＝緑⇔マゼンタ）も、色そのものを操作対象として提示する固定色であり同様に対象外とする。

## エラー処理

- フォルダ操作などユーザー操作の直接結果はAlertで表示する。
- サムネイルなどバックグラウンド処理の失敗は、処理全体を止めず適切なインライン通知を検討する。
- 一時的な成功通知はToastで表示し、現在のToastは約2秒で消去する。

## 開発状況

### 実装済み

フォルダ読み込み、セキュリティスコープ付き履歴、基本EXIF取得、サムネイル/高解像度画像ロード、SwiftData永続化、お気に入り・メモ、3表示モード、非破壊回転・トリミング、分析画面、外部アプリ起動連携、RAW現像編集（Core Image ベース、プレビューに回転・トリミングも反映、RAWの露出・WBはCIRAWFilter委譲、撮影時WBの実測/推定表示、4ホイールのトーン域マスク カラーグレーディング、RAWレンズ補正トグル、非RAW/プロファイル無しRAW向けの手動レンズ補正=歪曲・周辺光量・色収差、`schemaVersion` 5）、現像調整プリセット・コピー＆ペースト、現像結果のJPEG/TIFF書き出し（sRGB/Display P3、現像→超解像チェーン対応）、プレビュープロキシの永続キャッシュ＋バックグラウンド生成＋現像 Stage A 中立ベースの永続化（RAW読み込み高速化、`PreviewCacheStore` / `PreviewGenerator` / `develop-base-v1`、WYSIWYG 維持）。

### 制限付き・検証継続中

- Sigma fp LのPictureMode検出は暫定実装。
- サムネイル/一覧表示は引き続きImageIOの対応範囲でプレビューする（現像は「編集」タブ選択時のみ）。
- プレビュープロキシ層（`PreviewCacheStore` / `PreviewGenerator` / `develop-base-v1`）: 実RAW（NEF/ARW/CR3/RAF/DNG、24〜45MP）での前後比較計測（フォルダ再訪時の全画面表示、編集タブ初回のベース表示、露出スライダー release 後の再描画、フォルダ全プロキシ生成時間、ピークRSS、ディスク使用量）は実機・実ファイルが必要なため継続。プレビュー解像度・キャッシュ上限は `static let stored*` の起動時読みで次回起動反映（thumbnailQuality と同じ、UI に注記あり）。`asShotNeutral` は写真の初回選択ごとに走る（非RAW は 256px デコード＋グレーワールド、RAW は `CIRAWFilter` 生成、`.detached`）。プロキシデコードは色空間を sRGB 前提で扱う（現行 Stage A 出力と整合）が、広色域の埋め込みプレビューを持つ機種での検証は継続。
- 現像編集: カラー別HSLはCore Imageに単一フィルタが無いためCPU生成の3D LUT（`CIColorCube`）による近似。書き出しはsRGB / Display P3を選択可（`develop`の作業空間linearSRGBと出力段のsRGB LUTは維持し、実体化時にのみP3へ変換）。プレビューは既定sRGB、P3ディスプレイ上ではそのディスプレイの色空間で現像してP3書き出しの見えと一致させる（`DevelopViewModel.setPreviewColorSpace`、`DisplayColorSpaceReader` がウィンドウのディスプレイ移動・構成変更に追従、v3 Phase 4）。作業空間linearSRGBと知覚ブラケットは不変で実体化時にのみ変換。ヒストグラムは常にsRGB基準。RAWの露出・色温度・色かぶりは`CIRAWFilter`のas-shot既定からのオフセットとして委譲（`RAWDevelopMapping`、`DevelopSettings.schemaVersion` 2）。version 1の既存RAWレコードは標準チェーンのまま。ノイズ低減・シャープ・コントラスト等は標準`CIFilter`チェーンを維持（v3 Phase 6 で実RAW検証・却下: `CIRAWFilter`の`sharpnessAmount`/`luminanceNoiseReductionAmount`/`detailAmount`は`scaleFactor`≲0.75で効果が崖落ちし補正係数で吸収できず、縮小プレビューとフル解像度書き出しでWYSIWYGが破れる。`colorNoiseReductionAmount`のみ比較的安定だが単独委譲は割に合わず見送り）。RAWの露出・WBスライダーはドラッグ中は標準チェーンで近似し、離した時点で`CIRAWFilter`再デコードで描き直す。RAWのレンズプロファイル補正は`CIRAWFilter.isLensCorrectionEnabled`のトグル。加えて非RAW/プロファイル無しRAW向けに手動レンズ補正（歪曲・周辺光量・色収差、各 -100...100）を実装（v3 Phase 5、`schemaVersion` 3、`LensCorrectionFilter`）。歪曲は Metal の `[[stitchable]]` ワープ関数（`LensDistortion.ci.metal`、CIKernel専用ビルドフラグ不要）、周辺光量は`CIVignetteEffect`、色収差はR/Bチャンネルの中心基準リスケール。座標は extent 相対で持つのでプレビュー縮小とフル解像度で効きが一致。`DevelopPipeline` のチェーン先頭（幾何変形なので露出等より前）で適用し、RAWの`CIRAWFilter`レンズ補正が有効なときは二重補正を避けてスキップ。`BaseKey`/`decodeHash` は不変（Stage B のみ、スライダー操作で再デコードしない）。RAWのプロファイル補正が有効なときの二重補正回避判定はドラッグ非依存で VM 側（`DevelopViewModel.shouldApplyManualLensCorrection`）が計算する。既存の `schemaVersion` 2〜4 レコードは現像編集時に 5 へ自動バンプ（`setParameters`。追加値は中立既定で見た目不変）、`schemaVersion` 1 は据え置き。`usesManualLensCorrection` は `schemaVersion >= 2`、`usesToneMaskedColorGrading` は `schemaVersion >= 5`。カラーグレーディングはトーン域マスク方式（v3、`schemaVersion` 5）: 入力輝度（Rec.709）から shadow/mid/highlight マスクを作り、Master/Shadow/Midtone/Highlight 各ホイールの色オフセット（hue/saturation を極座標→RGB チントベクトル）＋輝度オフセットを加算する単一パスの Metal `[[stitchable]]` カラーカーネル（`ColorGrading.ci.metal` / `ColorGradingFilter`、`LensDistortion.ci.metal` と同じ流儀、ロード失敗時は入力を素通し）。知覚（ガンマsRGB）ブラケット内で適用。`schemaVersion < 5` の既存レコードは旧 `DevelopPipeline.applyColorBalanceLegacy`（4成分平均→単一適用）で描画し見た目を凍結。ホワイトバランスは絶対 Kelvin/Tint（`schemaVersion` 4〜、`WhiteBalanceSettings`）。撮影時WBは RAW が `CIRAWFilter.neutralTemperature/neutralTint` の as-shot 実測、非RAW は EXIF 色温度ベストエフォート→グレーワールド推定（`ImageDevelopmentEngine.asShotNeutral`、`WhiteBalanceSample.isEstimated`）。非RAW の Custom WB は as-shot 基準からのズレを 6500K 基準へ写像して `CITemperatureAndTint` へ渡す（`DevelopParameters.asShotTemperatureKelvin/asShotTint`、非RAW時に `DevelopViewModel.load` で焼き込み）。UI は色温度スライダー（青⇔黄グラデ）＋数値K、色かぶりスライダー（緑⇔マゼンタ）、As Shot 実測/推定キャプション（`WhiteBalanceSection`）。ビルドには Metal Toolchain コンポーネント（`xcodebuild -downloadComponent MetalToolchain`）が必要。回転・トリミングはプレビューにも焼き込むが、トリミング編集中のオーバーレイはベース画像上で操作する。RAW実ファイルでのデコード経路は実機サンプル不足のため継続検証中。詳細は `Docs/ShootLog_設計書.md` 6章。
- 現像パイプラインの色管理は v3 Phase 1 で 2 ブラケットに統一済み: リニア光（ホワイトバランス・露出・ハイライト/シャドウ・シャープ・ノイズ低減）と ガンマ sRGB（コントラスト・自然な彩度/彩度・白黒レベル・トーンカーブ・カラー別HSL・カラーグレーディング）。知覚ブラケットは `DevelopPipeline` 内で `CILinearToSRGBToneCurve` / `CISRGBToneCurveToLinear` で前後を挟み、区間内の `CIColorCurves` / `CIColorCubeWithColorSpace` は作業空間 linearSRGB を指定して再変換を避ける。span 定数（`contrastSpan` 等）のガンマ空間前提での実画像チューニングは A 系統作業として継続。
- 単体の超解像書き出し（`UpscaleExporter`）も `EditInfo.cropRect` を適用する（v3 Phase 2）。回転前の原本を表示画像基準の矩形へ逆変換して切り抜いてから回転・拡大するため、現像→超解像チェーンと同じ構図・寸法になる。上限判定・所要時間見積り（`UpscaleExportViewModel.croppedInputPixelSize`）も切り抜き後の画素数で行う。
- ネットワークドライブの性能最適化は継続改善する。
- 全操作要素のアクセシビリティ、エラー通知の網羅性、macOS 26のLiquid Glass対応は継続監査する。
- iCloud写真ライブラリ連携（`.omc/plans/icloud-photo-library-integration.md`）: Phase A〜D（権限基盤・一覧取得とサムネイル表示・フルサイズ表示とEXIF統合・キャッシュeviction）まで実装済み。詳細は「iCloud写真ライブラリの読み込み」章を参照。実機でのiCloud上のRAW写真表示、「Optimize Mac Storage」有効時のネットワーク経由ダウンロード体感、お気に入り・メモ・分析画面の実動作、キャッシュ削除の動作確認は未実施（実機・iCloud写真ライブラリが必要なため継続）。RAW現像編集・書き出し・超解像連携、限定アクセス時のブラウジングUIは引き続きスコープ外。

### 未着手・スコープ外

- ローカル調整（マスク・レイヤー）、レンズ補正プロファイルの自動適用/作成UI・外部プロファイル取り込み（lensfun形式等）
- 複数フォルダの同時表示
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
