#!/bin/bash
# ShootLog — プロジェクトセットアップスクリプト
# Claude Code に実行させるスクリプト。Homebrew と xcodegen が必要。
set -e

echo "🔧 ShootLog プロジェクトセットアップ開始"

# ── 1. xcodegen のインストール確認 ──────────────────────────────
if ! command -v xcodegen &> /dev/null; then
    echo "📦 xcodegen をインストール中..."
    brew install xcodegen
else
    echo "✅ xcodegen: $(xcodegen --version)"
fi

# ── 2. SwiftLint のインストール確認 ─────────────────────────────
if ! command -v swiftlint &> /dev/null; then
    echo "📦 SwiftLint をインストール中..."
    brew install swiftlint
else
    echo "✅ SwiftLint: $(swiftlint --version)"
fi

# ── 3. ディレクトリ構成を作成 ────────────────────────────────────
echo "📁 ディレクトリ構成を作成中..."

mkdir -p ShootLog/App
mkdir -p ShootLog/Features/Library/Views
mkdir -p ShootLog/Features/Library/ViewModels
mkdir -p ShootLog/Features/Viewer/Views
mkdir -p ShootLog/Features/Viewer/ViewModels
mkdir -p ShootLog/Features/Editor/Views
mkdir -p ShootLog/Features/Editor/ViewModels
mkdir -p ShootLog/Features/Analysis/Views
mkdir -p ShootLog/Features/Analysis/ViewModels
mkdir -p ShootLog/Features/Settings
mkdir -p ShootLog/Models
mkdir -p ShootLog/Services
mkdir -p ShootLog/Viewer
mkdir -p ShootLog/Integration/Adapters
mkdir -p ShootLog/Shared/UI
mkdir -p ShootLog/Shared/Extensions
mkdir -p ShootLog/Resources
mkdir -p "ShootLog/Preview Content/Preview Assets.xcassets"
mkdir -p ShootLog/Assets.xcassets/AppIcon.appiconset
mkdir -p Docs

# ── 4. ソースファイルを生成 ──────────────────────────────────────
echo "📝 ソースファイルを生成中..."

# エントリーポイント
cat > ShootLog/App/ShootLogApp.swift << 'SWIFT'
import SwiftUI
import SwiftData

@main
struct ShootLogApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // SwiftDataモデルをすべて登録
        .modelContainer(for: [Photo.self, EditInfo.self, FolderHistory.self])
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
SWIFT

# コンテンツビュー（最小実装）
cat > ShootLog/Features/Library/Views/ContentView.swift << 'SWIFT'
import SwiftUI

// アプリのルートビュー。フォルダ選択状態と表示モードに応じてビューを切り替える
struct ContentView: View {
    var body: some View {
        // Phase 1: 最小限の表示。Phase 5 以降で表示モード分岐を実装する
        Text("ShootLog")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
SWIFT

# Photoモデル
cat > ShootLog/Models/Photo.swift << 'SWIFT'
import Foundation
import SwiftData

/// 写真1枚に対応するSwiftDataモデル
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
    var colorMode: String?      // Sigma fp L 等のカラーモード名（例: "PowderBlue"）
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
SWIFT

# EditInfoモデル
cat > ShootLog/Models/EditInfo.swift << 'SWIFT'
import Foundation
import SwiftData

/// 非破壊編集情報。元ファイルは変更せず、表示・エクスポート時のみ適用する
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
SWIFT

# FolderHistoryモデル
cat > ShootLog/Models/FolderHistory.swift << 'SWIFT'
import Foundation
import SwiftData

/// フォルダアクセス履歴。最大10件を保持する
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
SWIFT

# ShootLogError
cat > ShootLog/Shared/ShootLogError.swift << 'SWIFT'
import Foundation

/// アプリ全体で使用するエラー定義
enum ShootLogError: LocalizedError {
    case exifReadFailed
    case unsupportedFormat(extension: String)
    case folderAccessDenied
    case bookmarkRestorationFailed

    var errorDescription: String? {
        switch self {
        case .exifReadFailed:
            return "EXIF情報の読み取りに失敗しました"
        case .unsupportedFormat(let ext):
            return "未対応の形式です: \(ext)"
        case .folderAccessDenied:
            return "フォルダへのアクセス権限がありません"
        case .bookmarkRestorationFailed:
            return "保存済みフォルダへのアクセスを復元できませんでした"
        }
    }
}
SWIFT

# Assets.xcassets
cat > ShootLog/Assets.xcassets/Contents.json << 'JSON'
{ "info": { "author": "xcode", "version": 1 } }
JSON

cat > ShootLog/Assets.xcassets/AppIcon.appiconset/Contents.json << 'JSON'
{ "images": [], "info": { "author": "xcode", "version": 1 } }
JSON

cat > "ShootLog/Preview Content/Preview Assets.xcassets/Contents.json" << 'JSON'
{ "info": { "author": "xcode", "version": 1 } }
JSON

# Info.plist
cat > ShootLog/Info.plist << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>ShootLog</string>
    <key>NSHumanReadableCopyright</key>
    <string></string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
XML

# Entitlements
cat > ShootLog/ShootLog.entitlements << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
</dict>
</plist>
XML

# ── 5. 設定ファイル ──────────────────────────────────────────────

# SwiftLint（英語識別子のため identifier_name の無効化不要）
cat > .swiftlint.yml << 'YAML'
opt_in_rules:
  - force_unwrapping
  - empty_count
  - closure_spacing

line_length: 120

excluded:
  - .build
  - DerivedData
YAML

# .gitignore
cat > .gitignore << 'GIT'
.DS_Store
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/
DerivedData/
.build/
*.o
*.d
GIT

# ── 6. Docsフォルダにドキュメントをコピー ───────────────────────
echo "📄 ドキュメントをDocsフォルダにコピー中..."
if [ -f "../CLAUDE.md" ]; then cp ../CLAUDE.md ./; fi
if [ -f "../ShootLog_プロジェクト規約書.md" ]; then
    cp ../ShootLog_プロジェクト規約書.md Docs/
fi
if [ -f "../UI_モックアップ.html" ]; then
    cp ../UI_モックアップ.html Docs/
fi

# ── 7. xcodegen でプロジェクト生成 ──────────────────────────────
echo "⚙️  xcodegen でプロジェクトを生成中..."
xcodegen generate

echo ""
echo "✅ セットアップ完了！"
echo ""
echo "次のステップ:"
echo "  1. open ShootLog.xcodeproj でXcodeを起動"
echo "  2. Signing & Capabilities でDevelopment Teamを設定"
echo "  3. Claude Code で 'CLAUDE.md を読んで Phase 1 の実装を始めてください' と伝える"
