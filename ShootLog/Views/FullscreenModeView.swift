import SwiftUI

// フルスクリーンモード。黒背景・左右ナビ・お気に入り・Esc でサイドバーへ戻る
struct FullscreenModeView: View {
    @Bindable var vm: FullscreenViewModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PhotoViewerView(photo: vm.selectedPhoto, editInfo: vm.currentEditInfo)

            // 左右ナビゲーションボタン
            HStack {
                NavButton(direction: .prev) { vm.selectPrevious() }
                Spacer()
                NavButton(direction: .next) { vm.selectNext() }
            }
            .padding(.horizontal, 8)

            // 上部 HUD: キーボードヒント / お気に入り / 閉じる
            VStack {
                HStack {
                    KeyboardHintView(["← →", "Esc"])
                    Spacer()
                    FavoriteButton(isFavorite: vm.selectedPhoto?.isFavorite ?? false) {
                        vm.toggleFavorite()
                    }
                    Spacer()
                    CloseButton { vm.switchToSidebar() }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                Spacer()
            }

            // 下部: ページドット + カウンター
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    PageDotsView(current: vm.selectedIndex, total: vm.photos.count)
                    Spacer()
                    Text("\(vm.selectedIndex + 1) / \(vm.photos.count)")
                        .font(HUDTypography.label)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassOrMaterialCapsule()
                        .padding(.trailing, 14)
                }
                .padding(.bottom, 10)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow)  { vm.selectPrevious(); return .handled }
        .onKeyPress(.rightArrow) { vm.selectNext();     return .handled }
        .onKeyPress(.escape)     { vm.switchToSidebar(); return .handled }
        .toolbar { toolbarItems }
    }

    // MARK: - Toolbar

    // sidebarモードと同一構成の標準ツールバー（OS標準の見た目に統一する）
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ModeTogglePicker(currentModeID: $vm.currentModeID)

            Button { vm.showFavoritesOnly.toggle() } label: {
                Image(systemName: vm.showFavoritesOnly ? "star.fill" : "star")
            }
            .help("お気に入りのみ表示")
            .accessibilityLabel("お気に入りのみ表示")
            .disabled(vm.photos.isEmpty)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { vm.openFolder() } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("フォルダを開く (⌘O)")
            .accessibilityLabel("フォルダを開く")

            Button { vm.openAnalysis() } label: {
                Image(systemName: "chart.bar")
            }
            .help("撮影傾向を分析 (⌘I)")
            .accessibilityLabel("分析")
            .keyboardShortcut("i", modifiers: .command)
            .disabled(vm.photos.isEmpty)

            ExternalAppMenu(onSelect: { adapter in vm.openInExternalApp(adapter) })
                .disabled(vm.selectedPhoto == nil)

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .help("設定を開く")
            .accessibilityLabel("設定を開く")
        }
    }
}

// MARK: - Helper Views

private struct NavButton: View {
    enum Direction { case prev, next }
    let direction: Direction
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .prev ? "chevron.left" : "chevron.right")
                .foregroundStyle(Color.onDarkCanvas)
                .frame(width: 44, height: 44)
                .glassOrMaterialCircle()
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.control))
        .accessibilityLabel(direction == .prev ? "前の写真" : "次の写真")
    }
}

private struct FavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? Color.yellow : Color.onDarkCanvasSecondary)
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .accessibilityLabel(isFavorite ? "お気に入りを解除" : "お気に入りに追加")
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.onDarkCanvasSecondary)
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .accessibilityLabel("サイドバーに戻る")
    }
}

private struct KeyboardHintView: View {
    let hints: [String]
    init(_ hints: [String]) { self.hints = hints }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(hints, id: \.self) { hint in
                Text(hint)
                    .font(HUDTypography.caption)
                    .foregroundStyle(Color.onDarkCanvasSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .glassOrMaterial(cornerRadius: 4)
            }
        }
    }
}

