# ShootLog フォルダ構成の再編成プラン

**ステータス: pending approval**（このプランはまだ実行されていません）

---

## 1. Requirements Summary

- 現在 `Features/<機能名>/{Views,ViewModels}` という機能単位のフォルダ構成になっているが、`Models/` `Services/` `Shared/` `Integration/` `Viewer/`（トップレベル）が層別に混在しており、ユーザーからは「乱立している」と評価されている。
- 目標: プロジェクト直下を **View / ViewModel / Model / その他** の層（レイヤー）で明確に分離する。
- ユーザー確認済みの方針:
  1. `Views/` `ViewModels/` の中身は機能ごとにサブフォルダ分割する（例: `Views/Library/`）。
  2. `project.pbxproj` を Xcode 16 の **Synchronized Root Group**（フォルダ同期方式）へ移行し、今後のファイル移動を Finder 操作だけで完結できるようにする。

## 2. 現状の問題点（調査結果）

| 問題 | 詳細 |
|---|---|
| 層とフォルダの不整合 | `Features/*` は機能単位、`Models/` `Services/` はトップレベルの層単位で、分類軸が混在している |
| 空フォルダの放置 | `Features/Settings/`（中身なし）, `Features/Editor/ViewModels/`（中身なし）, `Features/Viewer/ViewModels/`（中身なし）, `Shared/Extensions/`（中身なし）, `Resources/`（中身なし） |
| 名前衝突 | トップレベル `Viewer/`（`ViewModeProtocol.swift` `ViewModeRegistry.swift`）と `Features/Viewer/`（実際の表示View群）が同名で紛らわしい。`Viewer/CLAUDE.md` により意図的な設計だと判明（表示モードのプラグイン機構）だが、命名が混乱を招いている |
| 迷子のViewModel | `MainViewModel.swift`（アプリ全体の単一真実源、`Features/Library/ViewModels/` に配置）は Library 機能専用ではなくアプリ全体のルートViewModel |
| Xcodeプロジェクト形式 | `project.pbxproj` の `objectVersion = 77`（Xcode 16対応）だが `PBXFileSystemSynchronizedRootGroup` は未使用（0件）。全ファイルが旧来の明示的 `PBXFileReference` 方式 |
| テストターゲット | 存在しない（`PBXNativeTarget` は `ShootLog` の1つのみ） |
| Gitリポジトリ | 未初期化（`git status` 不可）。今回のような構造変更を安全に元に戻す手段が現状ない |

## 3. 新フォルダ構成（最終形・改訂版）

> **改訂理由**: 初版はトップレベル8フォルダ（`App/Views/ViewModels/Models/ViewModes/Services/Integration/Shared`）だったが、ユーザーから「多すぎる、減らせないか」との指摘を受け、`App` `ViewModes` `Services` `Integration` `Shared` を **`Core/`（その他）に統合**し、ユーザーが当初要望した **View / ViewModel / Model / その他 の4分類そのもの**に一致させた。

```
ShootLog/
├── ShootLogApp.swift                        (エントリポイント。1ファイルのみのため専用フォルダを作らずルート直下に置く)
├── Views/
│   ├── Main/
│   │   └── ContentView.swift                (Features/Library/Views から独立)
│   ├── Library/
│   │   ├── EmptyStateView.swift
│   │   ├── LibraryView.swift
│   │   └── PhotoListView.swift
│   ├── Analysis/
│   │   └── AnalysisView.swift
│   ├── Editor/
│   │   ├── CropOverlayView.swift
│   │   └── EditorToolbarView.swift
│   └── Viewer/
│       ├── EditablePhotoView.swift
│       ├── EXIFPanelView.swift
│       ├── FullscreenModeView.swift
│       ├── PhotoViewerView.swift
│       ├── SidebarModeView.swift
│       └── SlideshowModeView.swift
├── ViewModels/                               (実際に @Observable な ViewModel クラスのみを置く)
│   ├── Main/
│   │   └── MainViewModel.swift               (Features/Library/ViewModels から独立)
│   ├── Library/
│   │   └── LibraryViewModel.swift
│   └── Analysis/
│       └── AnalysisViewModel.swift
├── Models/                                   (変更なし・フラット維持。SwiftData @Model の3クラス)
│   ├── EditInfo.swift
│   ├── FolderHistory.swift
│   └── Photo.swift
└── Core/                                     ("その他" ― View/ViewModel/Modelのいずれにも属さないインフラ・支援コード
    ├── ViewModes/                            (トップレベル Viewer/ をリネーム＆Core配下に格納。ViewModeProtocol/Registryは
    │   │                                      @Observableな状態を持たず「どのViewを出すか選ぶFactory/Registry」であり
    │   │                                      ViewでもViewModelでもないためCoreに分類。Views/Viewerとの名前衝突も解消)
    │   ├── ViewModeProtocol.swift
    │   ├── ViewModeRegistry.swift
    │   └── CLAUDE.md                         (パス言及を Core/ViewModes/ に更新)
    ├── Services/
    │   ├── EXIFService.swift
    │   ├── ImageLoader.swift
    │   └── PhotoRepository.swift
    ├── Integration/
    │   ├── Adapters/
    │   │   ├── AffinityPhotoAdapter.swift
    │   │   ├── CaptureOneAdapter.swift
    │   │   ├── FinderAdapter.swift
    │   │   ├── LightroomAdapter.swift
    │   │   ├── PhotoshopAdapter.swift
    │   │   └── PreviewAdapter.swift
    │   └── ExternalAppProtocol.swift
    └── Shared/                               (Extensions/ は空のため削除。UIは維持)
        ├── ShootLogError.swift
        └── UI/
            ├── DesignSystem.swift
            ├── NativeSidebarToggleRemover.swift
            ├── PageDotsView.swift
            └── ToastView.swift

Assets.xcassets/                              (リソースカタログ。ソースコード分類の対象外・変更なし)
Preview Content/                              (同上)
```

**トップレベルは `Views/` `ViewModels/` `Models/` `Core/` の4フォルダ + ルート直下の `ShootLogApp.swift` + リソースカタログ2つ**に集約。これがまさにユーザーが当初要望した「View・ViewModel・Model・その他」の4分類。

削除する空フォルダ: `Features/Settings/`, `Features/Editor/ViewModels/`, `Features/Viewer/ViewModels/`, `Shared/Extensions/`, `Resources/`（Git管理下にないため実質即消滅。必要になったPhaseで再作成する）

**MVVM層の対応関係**: `Views/Main/ContentView.swift` ⇄ `ViewModels/Main/MainViewModel.swift`、`Views/Library/*` ⇄ `ViewModels/Library/LibraryViewModel.swift`、`Views/Analysis/*` ⇄ `ViewModels/Analysis/AnalysisViewModel.swift` という対応が一目でわかる構成にする。`Views/Editor/` `Views/Viewer/` はまだ専用ViewModelを持たない（Phase 6・7で追加予定、CLAUDE.md実装フェーズ表参照）。

## 4. Acceptance Criteria

- [ ] `find ShootLog -name "*.swift" | wc -l` が移行前後で **37件** のまま変わらない（1件も消失しない。※初版で「33件」としていたのは数え間違いで、正しくは37件）
- [ ] 上記「新フォルダ構成」のツリーと実際のディレクトリ構造が完全一致する
- [ ] `Features/` ディレクトリが存在しない
- [ ] トップレベルに `Viewer/` が存在せず、`Core/ViewModes/` が存在する
- [ ] 空フォルダ（`Settings/` `Resources/` `Shared/Extensions/` 等）が存在しない
- [ ] トップレベルのソースフォルダが `Views/` `ViewModels/` `Models/` `Core/` の4つ（+ ルート直下の `ShootLogApp.swift`）のみである
- [ ] `xcodebuild -project ShootLog.xcodeproj -scheme ShootLog -configuration Debug build` が **エラー0件** で成功する
- [ ] Xcodeでプロジェクトを開いた際、Project Navigator上に赤字（missing reference）のファイルが1件もない（目視確認）
- [ ] `Views` `ViewModels` `Models` `Core` の4フォルダが Xcode の Synchronized Root Group として登録され、`ShootLog` ターゲットのメンバーシップに含まれている
- [ ] アプリを実際に起動し、フォルダを1つ読み込んでサムネイル一覧が表示できる（スモークテスト、クラッシュなし）
- [ ] `.swift` ファイルの中身（import文・型定義・ロジック）は一切変更されていない（`Core/ViewModes/CLAUDE.md` のパス言及以外に差分がない）

## 5. Implementation Steps

### Step 0: 安全対策（最重要・最初に実施）
現在このプロジェクトは Git 管理下にない。ファイル移動 + `project.pbxproj` の書き換えという「壊れたら気づきにくく、元に戻す手段がない」作業を安全に行うため、着手前に以下のいずれかを必須で行う。
- `git init && git add -A && git commit -m "初期コミット: フォルダ再編成前のスナップショット"` を実行し、以降の作業をコミット単位で追跡可能にする（推奨）
- または `tar czf ~/Desktop/ShootLog_backup_$(date +%Y%m%d%H%M%S).tar.gz -C /Volumes/DataDisk/Developer/Xcode Shootlog` で丸ごとバックアップを取る

### Step 1: ファイルの物理移動
`mkdir -p` で新ディレクトリを作成し、`mv` で各 `.swift` ファイルを上記マッピング通りに移動する（37ファイル全件、上記ツリー参照）。`ShootLogApp.swift` は `App/` フォルダを介さず `ShootLog/` ルート直下へ移動する。`Viewer/CLAUDE.md` は `Core/ViewModes/CLAUDE.md` へ移動し、本文中の `Viewer/` への言及を `Core/ViewModes/` に書き換える。

### Step 2: 空ディレクトリの削除
移動後に空となった `Features/` 以下および `Resources/`, `Shared/Extensions/` を削除する。

### Step 3: `project.pbxproj` の移行
Ruby `xcodeproj` gem（マシンにインストール済みを確認済み）を使ったスクリプトで以下を実施する。手書きでの `project.pbxproj` 直接編集は破損リスクが高いため行わない。
1. 移動元パスを参照している既存の `PBXGroup` / `PBXFileReference` を除去
2. 新しい4トップレベルフォルダ（`Views` `ViewModels` `Models` `Core`）を `PBXFileSystemSynchronizedRootGroup` として追加し、`ShootLog` ターゲットの `fileSystemSynchronizedGroups` に登録（`Core` 配下の `ViewModes` `Services` `Integration` `Shared` はサブフォルダとして自動的に同期対象に含まれるため個別のRoot Group登録は不要）
3. `ShootLogApp.swift` は単一ファイルなので通常の `PBXFileReference` としてターゲットの `ShootLog` グループ直下に登録
4. `Assets.xcassets` / `Preview Content` は現状の classic 参照のまま変更しない（移動対象外のため）
5. プロジェクトファイルを保存

### Step 4: ビルド検証
- `xcodebuild clean -project ShootLog.xcodeproj -scheme ShootLog` でDerivedDataキャッシュによる誤検知を排除
- `xcodebuild -project ShootLog.xcodeproj -scheme ShootLog -configuration Debug build` を実行し、エラー0件を確認

### Step 5: Xcode目視確認（人手推奨）
Xcode.app でプロジェクトを開き、Project Navigatorに赤字ファイルがないこと、新しいフォルダ構成が同期グループとして正しく表示されていることを確認する。スクリプトによる `pbxproj` 編集は最終的にXcode自身の検証を通すのが最も確実なため、この手動確認ステップは省略しない。

### Step 6: スモークテスト
アプリを実行し、写真フォルダを1つ選択して読み込み、サムネイル一覧が表示されることを確認する（`verify` スキルの方針に沿い、ビルド成功だけでなく実際の動作を確認する）。

## 6. Risks and Mitigations

| リスク | 対策 |
|---|---|
| `project.pbxproj` 破損によりプロジェクトが開けなくなる | Step 0 のバックアップ/Git commit を必須の最初のステップとする。手書き編集はせず `xcodeproj` gem を使用 |
| Synchronized Root Group のターゲットメンバーシップ誤設定によりビルドから一部ファイルが漏れる | Step 3 のスクリプトで各ルートグループ追加時に明示的にターゲットメンバーシップを指定し、Step 5 でXcode上のメンバーシップインスペクタも目視確認する |
| `mv` の打ち間違いでファイルが消失・上書きされる | 移動は1ファイルずつ確認しながら実施し、Step完了後に `find ShootLog -name "*.swift" \| wc -l` で件数が37件のまま変わらないことを検証する |
| DerivedDataの古いキャッシュにより見せかけのビルドエラー/成功が出る | Step 4 で明示的に `xcodebuild clean` を先に実行する |
| `ViewModes/CLAUDE.md` のリネームにより将来の開発者が旧パス `Viewer/` を参照してしまう | ドキュメント本文を機械的に書き換えるだけでなく、フォルダ名自体を変更するため参照は自然に追従する |
| Gitがない状態で作業が進み、万一の際に差分確認ができない | Step 0 で `git init` を強く推奨。ユーザーがGit導入を望まない場合はtarバックアップを必須とする |

## 7. Verification Steps

1. `find ShootLog -name "*.swift" | wc -l` → 37件であることを確認
2. 新ツリー構成とディレクトリ構造の一致を `find ShootLog -type d` で確認
3. `xcodebuild clean && xcodebuild build` がエラー0件で完了することを確認
4. Xcode.app でプロジェクトを開き、Navigator上に赤字ファイルがないことを目視確認
5. アプリを起動し、フォルダ読み込み〜サムネイル表示までのスモークテストを実施
6. （Git導入した場合）`git diff --stat` でリネーム・移動のみが検出され、`.swift` ファイルの中身に意図しない差分がないことを確認

---

## 変更履歴

- 初版作成。ユーザー確認事項: (1) Views/ViewModelsは機能別サブフォルダに分割, (2) project.pbxprojはSynchronized Root Group方式へ移行。
- 改訂1: ユーザーから「トップレベル8フォルダは多すぎる」との指摘を受け、`App` `ViewModes` `Services` `Integration` `Shared` を `Core/` に統合し、トップレベルを `Views/ViewModels/Models/Core` の4フォルダ（+ ルート直下の `ShootLogApp.swift`）に削減。あわせてSwiftファイル件数の数え間違い（誤: 33件 → 正: 37件）を全箇所修正。
