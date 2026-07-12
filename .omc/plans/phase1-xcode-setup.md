# ShootLog Phase 1 — Xcodeプロジェクト作成・Entitlements・SwiftDataモデル

**Status**: approved for execution  
**Date**: 2026-06-27

---

## Requirements Summary

CLAUDE.md Phase 1:
- Xcodeプロジェクト作成
- Entitlements設定（App Sandbox / user-selected read-write / bookmarks app-scope）
- SwiftDataモデル定義（Photo / EditInfo / FolderHistory）

## Acceptance Criteria

- [ ] `ShootLog.xcodeproj` が生成される
- [ ] `SwiftVersion = 6.0`, `DeploymentTarget = macOS 14.0`
- [ ] `com.apple.security.app-sandbox = true`
- [ ] `com.apple.security.files.user-selected.read-write = true`
- [ ] `com.apple.security.files.bookmarks.app-scope = true`
- [ ] `Photo`, `EditInfo`, `FolderHistory` が `@Model` で定義済み
- [ ] `ShootLogError` が `LocalizedError` 準拠で定義済み
- [ ] `xcodebuild -list` が正常終了する

## Implementation Steps

### Step 1: setup.sh 実行
```
cd /Volumes/DataDisk/Developer/Xcode/Shootlog
bash setup.sh
```
setup.sh が行うこと:
- xcodegen / SwiftLint インストール確認
- ディレクトリ構成作成（ShootLog/App, Features, Models, Services, Shared 等）
- ソースファイル生成（ShootLogApp.swift, ContentView.swift, Photo.swift, EditInfo.swift, FolderHistory.swift, ShootLogError.swift）
- Assets.xcassets / Info.plist / Entitlements 生成
- `.swiftlint.yml` / `.gitignore` 生成
- `xcodegen generate` で .xcodeproj 生成

### Step 2: 生成物検証
- `ShootLog.xcodeproj` 存在確認
- `xcodebuild -list -project ShootLog.xcodeproj` 正常終了確認
- Entitlements の3キー確認

### Step 3: 必要なら補完実装
setup.sh 生成コードで不足があれば追加（CLAUDE.md の `@Observable @MainActor` パターン等）

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| xcodegen 未インストール | setup.sh が自動インストール |
| Swift 6 strict concurrency エラー | project.yml に `SWIFT_STRICT_CONCURRENCY: complete` 設定済み |
| Entitlements パス不一致 | project.yml の `entitlements.path` で明示指定 |

## Verification Steps

1. `xcodebuild -list` → scheme "ShootLog" が表示される
2. `grep -r "app-sandbox" ShootLog/ShootLog.entitlements` → true
3. `grep "@Model" ShootLog/Models/*.swift` → 3ファイル全てヒット
