import SwiftUI

// スライドショーモード。黒背景・自動再生・Space で一時停止・Esc でサイドバーへ戻る
struct SlideshowModeView: View {
    var vm: MainViewModel
    @State private var isPlaying = true
    @State private var interval: Double = 3.0
    @State private var progress: Double = 0.0
    @State private var timerTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PhotoViewerView(photo: vm.selectedPhoto, editInfo: vm.currentEditInfo)

            // 速度選択（左上）
            VStack {
                HStack(spacing: 4) {
                    ForEach([2.0, 3.0, 5.0], id: \.self) { sec in
                        Button("\(Int(sec))s") { interval = sec; restartTimer() }
                            .font(.system(size: 11, weight: interval == sec ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glassOrMaterial(cornerRadius: 5)
                            .opacity(interval == sec ? 1.0 : 0.55)
                            .animation(.easeInOut(duration: 0.15), value: interval)
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
                        vm.selectPrevious(); progress = 0
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .foregroundStyle(Color.onDarkCanvasSecondary)
                    }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityLabel("前の写真")

                    // 再生・一時停止
                    Button {
                        isPlaying.toggle()
                        if isPlaying { restartTimer() } else { timerTask?.cancel() }
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(Color.onDarkCanvas)
                    }
                    .buttonStyle(HUDButtonStyle(font: HUDTypography.controlLarge))
                    .accessibilityLabel(isPlaying ? "一時停止" : "再生")

                    // 次の写真
                    Button {
                        advanceSlideshow()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .foregroundStyle(Color.onDarkCanvasSecondary)
                    }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityLabel("次の写真")

                    // プログレスバー
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                        .tint(Color.onDarkCanvasSecondary)

                    Text("\(Int(interval))s")
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
            restartTimer()
        }
        .onDisappear { timerTask?.cancel() }
        .onKeyPress(.space)  { isPlaying.toggle(); if isPlaying { restartTimer() } else { timerTask?.cancel() }; return .handled }
        .onKeyPress(.escape) { vm.switchToSidebar(); return .handled }
    }

    // MARK: - Private

    private func restartTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            // 0.1 秒ごとに進捗を更新する（Combine 不使用）
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                if isPlaying {
                    progress += 0.1 / interval
                    if progress >= 1.0 { advanceSlideshow() }
                }
            }
        }
    }

    private func advanceSlideshow() {
        progress = 0
        if vm.selectedIndex + 1 < vm.photos.count {
            vm.selectNext()
        } else {
            // 最後まで来たら先頭に戻る
            vm.selectPhoto(vm.photos.first)
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

    @MainActor func makeView(vm: MainViewModel) -> AnyView {
        AnyView(SlideshowModeView(vm: vm))
    }
}
