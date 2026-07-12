# 調査計画: RAWデコード時のシステムログノイズ調査

status: pending approval

## 背景

実行時に以下2種のログが出る:

1. `cannot open file at line 51044 of [f0ca7bba1c] os_unix.c:51044: (2) open(/private/var/db/DetachedSignatures)`
2. `IOSurface creation failed: e00002c2 parentID: 00000000 ... IOSurfaceName = CMPhoto` (バッファサイズ例: 12,112,170 / 41,714,644 バイト)

アプリ自身のコードに `CMPhoto` / `CoreMedia` / `QuickLook` / 生SQLite呼び出しは存在しない（Explore調査済み）。
バッファサイズ(12MB, 41MB)はRAWのフル解像度デコード規模と一致 → `ImageLoader.swift` の以下箇所がトリガー候補:

- `highResImage(for:)` の `CGImageSourceCreateImageAtIndex`（ImageLoader.swift:113）— フル解像度デコード
- `loadCGThumbnail(from:)` のフォールバックパス `kCGImageSourceCreateThumbnailFromImageAlways`（ImageLoader.swift:165-170）— 埋め込みプレビューが小さい場合のフルデコード

両ログとも、macOSのRAWデコードパイプライン（RawCamera.framework / ImageIO内部）が、App Sandbox環境下でハードウェア支援デコード用IOSurfaceの確保に失敗し、ソフトウェアデコードへフォールバックする際の既知の副作用ログである可能性が高い。SQLite側のログも同様にOS内部の署名検証由来で、アプリのSwiftDataストアとは無関係と推測される。ただし推測に留め、実害の有無を検証するのが本計画の目的。

## 受け入れ基準（検証可能）

- [ ] ログが出た瞬間に対応する写真（RAWファイル）を特定し、サムネイル/フル解像度画像が正しいピクセルサイズ・内容で表示されることを確認する
- [ ] ログ出力とアプリのクラッシュ・画像欠落・応答なしとの間に相関がないことを確認する（Console.appのタイムスタンプ突合）
- [ ] `com.apple.security.app-sandbox` を一時的に無効化したビルドでIOSurfaceログが消えるか確認し、サンドボックス起因かを切り分ける
- [ ] `DetachedSignatures` ログがXcodeデバッグビルド固有（Ad-hoc/未公証）か、Release/公証済みビルドでも出るかを確認する
- [ ] 上記の結果を基に「無害な既知ノイズ」か「要修正の実害」かを結論づける

## 実装（調査）ステップ

1. **再現条件の特定**: `.nef`/`.dng`/`.arw`/`.cr3`/`.raf` のうち、どのフォーマット・どのサイズのファイルで発生するか、フォルダを開いてサムネイル表示時／写真選択してフル解像度表示時のどちらで出るかを切り分ける（`ImageLoader.swift:34` `thumbnail(for:)` と `ImageLoader.swift:85` `highResImage(for:)` それぞれ単独でトリガーして確認）
2. **Console.appでの相関確認**: `log stream --predicate 'process == "ShootLog"'` 等でアプリ側ログとシステムログのタイムスタンプを突合し、画像表示が実際に成功しているか（`NSImage` が nil で返っていないか）を `ImageLoader.swift:70` `guard let cgImage else { return nil }` 通過の有無で確認する
3. **サンドボックス切り分け**: Xcodeスキームで一時的にApp Sandboxをオフにしたビルドを作成し、同じRAWファイルで同じログが出るか比較する（Entitlements変更は調査用ブランチのみ、コミットしない）
4. **署名切り分け**: 可能であれば `codesign --sign` でad-hoc署名したビルドと未署名ビルドで `DetachedSignatures` ログの有無を比較する
5. **画質・完全性チェック**: ログ発生時に生成されたサムネイル（ディスクキャッシュ `~/Library/Caches/com.shootlog.app/thumbnails-v4/`）とフル解像度画像を実ファイルと目視・ピクセル寸法比較し、劣化や欠損がないか確認する

## リスクと対策

- **リスク**: サンドボックスを一時オフにする実験用ビルドを誤ってコミット/配布してしまう → **対策**: 調査用ブランチもしくはローカルのみの変更とし、Entitlements変更はコミット前に必ず元に戻す
- **リスク**: ログ自体は無害でも将来のOSアップデートで挙動が変わり実害化する可能性 → **対策**: 結論を本ファイルに残し、次回OSアップデート時の再確認ポイントとして記録する

## 検証ステップ

- 上記5ステップの実施結果（ログ有無・画像の正当性）をこのファイルの「結果」セクションに追記する
- 実害が確認された場合は別途修正計画を新規に起票する（本計画はスコープに含めない）

## 結果

（未実施）
