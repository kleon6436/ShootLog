# ShootLog

macOS向けの写真管理・閲覧アプリです。写真フォルダを読み込み、EXIF情報や撮影設定を確認しながら、複数の表示モードで写真を閲覧できます。

## 主な機能

- Open PanelまたはFinderからのドラッグ＆ドロップによるフォルダ読み込み
- セキュリティスコープブックマークを使った最近のフォルダ履歴（最大10件）
- JPEG、HEIC、TIFF、PNG、NEF、DNG、ARW、CR3、RAFの表示
- フォルダ直下の画像ファイルだけを対象にした読み込み
- ImageIOによるEXIF取得（カメラ、レンズ、絞り、シャッター速度、ISO、焦点距離、撮影日時）
- 埋め込みプレビュー優先のサムネイル表示、メモリ/ディスクキャッシュ
- ネットワークドライブ向けのサムネイル同時実行制限
- お気に入り登録、Favorites Only絞り込み、写真メモ
- サイドバー、フルスクリーン、スライドショー表示
- EXIFパネルの表示切り替え
- 回転・トリミング情報の保存（元画像を変更しない非破壊編集）
- 絞り、シャッター速度、ISOなどの撮影設定分析
- Capture One、Lightroom、Photoshop、Affinity Photo、Preview、Finderで写真を開く連携

## 対応環境

- macOS 14 Sonoma以降
- Swift 6.0
- SwiftUI、AppKit、SwiftData、ImageIO
- App Sandbox有効
- Bundle ID: `com.shootlog.app`

## 開発環境のセットアップ

プロジェクト設定は `project.yml` で管理しています。XcodeGenでプロジェクトを生成する場合は、XcodeGenをインストールした環境で `project.yml` を使用してください。生成済みの `ShootLog.xcodeproj` はそのままXcodeで開けます。

Xcodeで `ShootLog.xcodeproj` を開き、`ShootLog` schemeを選択して実行します。フォルダを選択すると写真の読み込みが始まります。

署名なしのビルド確認は、プロジェクトルートで行います。

```text
xcodebuild -project ShootLog.xcodeproj -scheme ShootLog -sdk macosx build CODE_SIGNING_ALLOWED=NO
```

## ディレクトリ構成

```text
ShootLog/
├── Core/
│   ├── Integration/       # 外部アプリ連携
│   ├── Services/          # EXIF・画像ロード・写真URLスキャン
│   └── ShootLogError.swift
├── Models/                # SwiftDataモデル
├── ViewModels/            # 画面状態と操作
└── Views/                 # SwiftUI画面
```

## 現在の制限

- 一度に開けるフォルダは1つだけです。サブフォルダは再帰的に読み込みません。
- RAW現像や露出・色温度などの本格編集は行わず、ImageIOの対応範囲でプレビューします。
- Sigma fp LのPictureMode検出は暫定実装で、実機サンプルによる検証を継続しています。
- 外部アプリ連携は選択中の写真を開く機能が中心で、双方向同期には対応していません。
- iCloud写真ライブラリ、GPS地図表示、顔検出、比較ビューには対応していません。

## 開発状況

### 実装済み

フォルダ読み込み、履歴、EXIF表示、サムネイル/高解像度画像ロード、SwiftData永続化、お気に入り・メモ、3表示モード、非破壊編集、撮影設定分析、外部アプリ起動連携を実装しています。

### 今後の改善

Sigma fp Lのカラーモード検出精度、ネットワークドライブでの性能、アクセシビリティ監査、エラー通知の網羅性、macOS 26向けLiquid Glass対応を継続します。

## 参考資料

- 開発規約: [`CLAUDE.md`](CLAUDE.md)
- 詳細設計: [`Docs/ShootLog_プロジェクト規約書.md`](Docs/ShootLog_プロジェクト規約書.md)
- UIモックアップ: [`Docs/UI_モックアップ.html`](Docs/UI_モックアップ.html)
