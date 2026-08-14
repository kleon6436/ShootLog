import SwiftUI

// スライドショーモード。黒背景・自動再生・Space で一時停止・Esc でサイドバーへ戻る
struct SlideshowModeView: View {
    @Bindable var vm: SlideshowViewModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.viewerCanvas.ignoresSafeArea()

            PhotoViewerView(photo: vm.selectedPhoto, editInfo: vm.currentEditInfo)

            // 速度選択（左上）
            VStack {
                HStack(spacing: 4) {
                    ForEach([2.0, 3.0, 5.0], id: \.self) { sec in
                        let isSelected = vm.interval == sec
                        Button {
                            vm.setInterval(sec)
                        } label: {
                            Text(verbatim: "\(Int(sec))s")
                                .font(HUDTypography.label)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundStyle(isSelected ? Color.onViewerCanvas : Color.onViewerCanvasSecondary)
                                .frame(width: 44, height: 44)
                                .glassOrMaterialCircle()
                        }
                        .buttonStyle(HUDButtonStyle(font: HUDTypography.label))
                        .animation(.easeInOut(duration: 0.15), value: vm.interval)
                        .accessibilityLabel("a11y.slideshow.interval \(Int(sec))")
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
                    RotateButton(shortcut: KeyEquivalent("r")) {
                        vm.rotateSelectedPhoto()
                    }
                    .disabled(vm.selectedPhoto == nil)

                    Button {
                        vm.switchToSidebar()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.onViewerCanvasSecondary)
                            .frame(width: 44, height: 44)
                            .glassOrMaterialCircle()
                    }
                    .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
                    .accessibilityLabel("viewer.backToSidebar")
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
                            .foregroundStyle(Color.onViewerCanvasSecondary)
                    }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityLabel("viewer.previousPhoto")

                    // 再生・一時停止
                    Button {
                        vm.togglePlayback()
                    } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(Color.onViewerCanvas)
                    }
                    .buttonStyle(HUDButtonStyle(font: HUDTypography.controlLarge))
                    .accessibilityLabel(vm.isPlaying ? "slideshow.pause" : "slideshow.play")

                    // 次の写真
                    Button {
                        vm.advanceSlideshow()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .foregroundStyle(Color.onViewerCanvasSecondary)
                    }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityLabel("viewer.nextPhoto")

                    // プログレスバー
                    ProgressView(value: vm.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                        .tint(Color.onViewerCanvasSecondary)

                    Text(verbatim: "\(vm.remainingSeconds)s")
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
                    CounterBadge(text: vm.visibleCounterText)
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

            FavoritesOnlyToggleButton(
                showFavoritesOnly: $vm.showFavoritesOnly,
                isDisabled: vm.photos.isEmpty
            )
        }

        ViewerToolbarTrailingGroup(
            isPhotosEmpty: vm.photos.isEmpty,
            hasSelectedPhoto: vm.selectedPhoto != nil,
            externalApps: vm.externalApps,
            openFolder: { vm.openFolder() },
            openAnalysis: { vm.openAnalysis() },
            openInExternalApp: { adapter in vm.openInExternalApp(adapter) },
            openSettings: { openSettings() }
        )
    }
}

// MARK: - Helper Views

