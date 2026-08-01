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
                        let isSelected = vm.interval == sec
                        Button {
                            vm.setInterval(sec)
                        } label: {
                            Text("\(Int(sec))s")
                                .font(HUDTypography.label)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundStyle(isSelected ? Color.onDarkCanvas : Color.onDarkCanvasSecondary)
                                .frame(width: 44, height: 44)
                                .glassOrMaterialCircle()
                        }
                        .buttonStyle(HUDButtonStyle(font: HUDTypography.label))
                        .animation(.easeInOut(duration: 0.15), value: vm.interval)
                        .accessibilityLabel("\(Int(sec))秒間隔")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.top, 10)
                Spacer()
            }

            // 回転・閉じるボタン（右上）
            VStack {
                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        vm.rotateSelectedPhoto()
                    } label: {
                        Image(systemName: "rotate.right")
                            .foregroundStyle(Color.onDarkCanvasSecondary)
                            .frame(width: 44, height: 44)
                            .glassOrMaterialCircle()
                    }
                    .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
                    .help("右に90度回転 (R)")
                    .accessibilityLabel("写真を右に90度回転")
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(vm.selectedPhoto == nil)

                    Button {
                        vm.switchToSidebar()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.onDarkCanvasSecondary)
                            .frame(width: 44, height: 44)
                            .glassOrMaterialCircle()
                    }
                    .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
                    .accessibilityLabel("サイドバーに戻る")
                }
                .padding(.trailing, 12)
                .padding(.top, 10)
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
                        vm.togglePlayback()
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

            // インデックスカウンター（右下）。自動送り（advanceSlideshow）が
            // お気に入りのみ表示の絞り込みを基準に動くため、表示も同じ基準に揃える
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(vm.visibleCounterText)
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
            vm.startPlayback()
        }
        .onDisappear { vm.stopPlayback() }
        .onKeyPress(.space)  { vm.togglePlayback(); return .handled }
        .onKeyPress(.escape) { vm.switchToSidebar(); return .handled }
        .toolbar { toolbarItems }
    }

    // MARK: - Toolbar

    // sidebarモードと同一構成の標準ツールバー（OS標準の見た目に統一する）
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ModeTogglePicker(currentModeID: $vm.currentModeID, modes: vm.availableModes)

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

            ExternalAppMenu(apps: vm.externalApps, onSelect: { adapter in vm.openInExternalApp(adapter) })
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

