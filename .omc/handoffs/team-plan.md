## Handoff: team-plan → team-exec

- **Decided**: フォルダ構成を `Views/ ViewModels/ Models/ Core/`（+ ルート直下 `ShootLogApp.swift`）の4層に再編成。`Views/ViewModels` は機能別サブフォルダ（Main/Library/Analysis/Editor/Viewer）。`Core/` に `ViewModes/ Services/ Integration/ Shared/` を統合。`project.pbxproj` は Xcode16 Synchronized Root Group方式へ移行。
- **Rejected**: 初版のトップレベル8フォルダ案（`App/Views/ViewModels/Models/ViewModes/Services/Integration/Shared`）はユーザーから「多すぎる」と却下され、Core統合案に変更。
- **Risks**: Gitリポジトリ未初期化のため、着手前に `git init` + 初期コミットを必須実施。`project.pbxproj` の手書き編集は破損リスクが高いため `xcodeproj` gem（インストール確認済み）を使用。Synchronized Root Group がインストール済みgemバージョンで未対応の場合は classic 参照方式へフォールバックし、その旨を報告すること。
- **Files**: 完全な移行元→移行先マッピングと詳細ステップは `/Volumes/DataDisk/Developer/Xcode/Shootlog/.omc/plans/folder-reorganization.md` を参照。
- **Remaining**: team-exec でファイル移動+pbxproj移行を実施 → team-verify でビルド検証・スモークテストを実施。
