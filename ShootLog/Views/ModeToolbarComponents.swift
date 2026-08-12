import SwiftUI

// 全表示モード（sidebar/fullscreen/slideshow）の標準ツールバーで共有する部品群。
// ForEachをツールバー式に直接書くと型検査がタイムアウトするため独立Viewへ切り出している

// ツールバー内の表示モード切替（セグメント）。モード一覧は呼び出し元のVM経由で渡す
// （ViewModeRegistry.sharedへのアクセスはVM層に閉じ、View層からは直接参照しない）
struct ModeTogglePicker: View {
    @Binding var currentModeID: String
    let modes: [any ViewModeProtocol]

    var body: some View {
        Picker("toolbar.viewMode", selection: $currentModeID) {
            ForEach(modes, id: \.id) { mode in
                Image(systemName: mode.symbolName)
                    .accessibilityLabel(Text(mode.displayName))
                    .tag(mode.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("toolbar.viewMode")
    }
}

// 外部アプリで開くメニュー。アプリ一覧は呼び出し元のVM経由で渡す
// （ExternalAppRegistry.sharedへのアクセスはVM層に閉じ、View層からは直接参照しない）
struct ExternalAppMenu: View {
    let apps: [any ExternalAppProtocol]
    let onSelect: (any ExternalAppProtocol) -> Void

    var body: some View {
        Menu {
            ForEach(apps, id: \.id) { adapter in
                Button { onSelect(adapter) } label: {
                    Label(adapter.displayName, systemImage: adapter.symbolName)
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .help("toolbar.externalApp.help")
        .accessibilityLabel("toolbar.externalApp.help")
    }
}

// お気に入りのみ表示の絞り込みトグル。3モード共通のボタン本体だけを共有し、
// ToolbarItemGroupへの配置は各モードのView側に残す（sidebarモードのみ隣接アイテムが異なるため）
struct FavoritesOnlyToggleButton: View {
    @Binding var showFavoritesOnly: Bool
    let isDisabled: Bool

    var body: some View {
        Button { showFavoritesOnly.toggle() } label: {
            Image(systemName: showFavoritesOnly ? "star.fill" : "star")
        }
        .help("toolbar.favoritesOnly")
        .accessibilityLabel("toolbar.favoritesOnly")
        .disabled(isDisabled)
    }
}

// 3モード共通のツールバー末尾グループ（分析・外部アプリ・設定）。
// fullscreen/slideshowモードでは同じグループの先頭に「フォルダを開く」が並ぶため
// openFolderを任意で受け取る。sidebarモードは同ボタンを.navigation配置に持つのでnilで呼ぶ
struct ViewerToolbarTrailingGroup: ToolbarContent {
    let isPhotosEmpty: Bool
    let hasSelectedPhoto: Bool
    let externalApps: [any ExternalAppProtocol]
    var openFolder: (() -> Void)?
    let openAnalysis: () -> Void
    let openInExternalApp: (any ExternalAppProtocol) -> Void
    let openSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let openFolder {
                Button { openFolder() } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("toolbar.openFolder.help")
                .accessibilityLabel("common.openFolder")
            }

            Button { openAnalysis() } label: {
                Image(systemName: "chart.bar")
            }
            .help("toolbar.analysis.help")
            .accessibilityLabel("toolbar.analysis")
            .keyboardShortcut("i", modifiers: .command)
            .disabled(isPhotosEmpty)

            ExternalAppMenu(apps: externalApps, onSelect: openInExternalApp)
                .disabled(!hasSelectedPhoto)

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .help("toolbar.settings")
            .accessibilityLabel("toolbar.settings")
        }
    }
}

// 黒背景HUD上の回転ボタン。fullscreen/slideshowモードでスタイル・ラベルを揃える。
// slideshowモードのみRキーのショートカットを持つためshortcutを任意で受け取る
struct RotateButton: View {
    let action: () -> Void
    var shortcut: KeyEquivalent?

    init(shortcut: KeyEquivalent? = nil, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "rotate.right")
                .foregroundStyle(Color.onDarkCanvasSecondary)
                .frame(width: 44, height: 44)
                .glassOrMaterialCircle()
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .help("toolbar.rotate.help")
        .accessibilityLabel("a11y.toolbar.rotate")
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: []) })
    }
}

// 黒背景HUD右下のインデックスカウンター。外側のpaddingは呼び出し側で付与する
struct CounterBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(HUDTypography.label)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassOrMaterialCapsule()
    }
}
