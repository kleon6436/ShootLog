import SwiftUI

// スライドショーモード。黒背景・自動再生・Space で一時停止・Esc でサイドバーへ戻る
struct SlideshowModeView: View {
    @Bindable var vm: SlideshowViewModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PhotoViewerView(photo: vm.selectedPhoto, editInfo: vm.currentEditInfo)

            // 速度選択（左上）
            VStack {
                HStack(spacing: 4) {
                    ForEach([2.0, 3.0, 5.0], id: \.self) { sec in
                        Button("\(Int(sec))s") { vm.interval = sec; vm.restartTimer() }
                            .font(.system(size: 11, weight: vm.interval == sec ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glassOrMaterial(cornerRadius: 5)
                            .opacity(vm.interval == sec ? 1.0 : 0.55)
                            .animation(.easeInOut(duration: 0.15), value: vm.interval)
                            .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.top, 10)
                Spacer()
            }

            // 閉じるボタン（右上）
            VStack {
                HStack {
                    Spacer()
                    Button {
                        vm.switchToSidebar()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.onDarkCanvasSecondary)
                    }
                    .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
                    .accessibilityLabel("サイドバーに戻る")
                    .padding(12)
                }
                Spacer()
            }

            // 再生コントロール＋プログレスバー（下部中央）
            VStack {
                Spacer()
                HStack(spacing: 14) {
                    // 前の写真
                    Button {
                        vm.selectPrevious()
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .foregroundStyle(Color.onDarkCanvasSecondary)
                    }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityLabel("前の写真")

                    // 再生・一時停止
                    Button {
                        vm.isPlaying.toggle()
                        if vm.isPlaying { vm.restartTimer() } else { vm.timerTask?.cancel() }
                    } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(Color.onDarkCanvas)
                    }
                    .buttonStyle(HUDButtonStyle(font: HUDTypography.controlLarge))
                    .accessibilityLabel(vm.isPlaying ? "一時停止" : "再生")

                    // 次の写真
                    Button {
                        vm.advanceSlideshow()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .foregroundStyle(Color.onDarkCanvasSecondary)
                    }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityLabel("次の写真")

                    // プログレスバー
                    ProgressView(value: vm.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                        .tint(Color.onDarkCanvasSecondary)

                    Text("\(Int(vm.interval))s")
                        .font(HUDTypography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassOrMaterial(cornerRadius: 20)
                .padding(.bottom, 12)
            }

            // インデックスカウンター（右下）
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("\(vm.selectedIndex + 1) / \(vm.photos.count)")
                        .font(HUDTypography.label)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassOrMaterialCapsule()
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            vm.restartTimer()
        }
        .onDisappear { vm.timerTask?.cancel() }
        .onKeyPress(.space)  { vm.isPlaying.toggle(); if vm.isPlaying { vm.restartTimer() } else { vm.timerTask?.cancel() }; return .handled }
        .onKeyPress(.escape) { vm.switchToSidebar(); return .handled }
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

// 黒背景 HUD 上のボタン共通スタイル。押下時に軽く減光・縮小してネイティブな反応を出す
private struct HUDButtonStyle: ButtonStyle {
    var font: Font?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - SlideshowMode 登録用

struct SlideshowMode: @MainActor ViewModeProtocol {
    let id = "slideshow"
    let displayName = "スライドショー"
    let symbolName = "play.rectangle"
    let keyboardShortcut: KeyEquivalent? = "p"
    private let box = ViewModelBox<SlideshowViewModel>()

    @MainActor func makeView(vm: ContentViewModel) -> AnyView {
        AnyView(SlideshowModeView(vm: box.get { SlideshowViewModel(content: vm) }))
    }
}
