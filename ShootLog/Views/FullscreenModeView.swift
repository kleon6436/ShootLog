import AppKit
import SwiftUI

// フルスクリーンモード。黒背景・左右ナビ・お気に入り・回転・ズーム/パン。Esc でサイドバーへ戻る。
// HUD（上部/下部オーバーレイ＋ウィンドウツールバー）は無操作で自動的に隠れ、
// マウス移動やキー操作で再表示する（macOS 写真.app 相当の挙動）
struct FullscreenModeView: View {
    @Bindable var vm: FullscreenViewModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isFocused: Bool

    // HUD内のキーボードフォーカス位置。フォーカスがHUD内にある間は自動的に隠さない
    @FocusState private var focusedHUDControl: HUDControl?

    // ズーム/パンはこのViewのローカル状態として持つ。ViewModelBoxにキャッシュされる
    // FullscreenViewModelへ置くとモード往復で意図せず永続化されてしまうため（ADR参照）
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureMagnification: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var gesturePanTranslation: CGSize = .zero
    @State private var isGestureActive = false

    // ズーム上限・パンのクランプ計算に使う実測値
    @State private var viewportSize: CGSize = .zero
    @State private var displayedImagePixelSize: CGSize = .zero

    // HUD内のフォーカス対象
    private enum HUDControl: Hashable {
        case previous, next, favorite, rotate, close
    }

    // ダブルクリック時に切り替えるズーム倍率
    private let doubleClickZoomScale: CGFloat = 2.0
    // キーボードショートカット1回あたりのズーム変化量
    private let keyboardZoomStep: CGFloat = 1.25

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            photoLayer

            if vm.isHUDVisible {
                navigationOverlay
                topHUD
                bottomHUD
            }
        }
        .contentShape(Rectangle())
        // .ended は「ツールバーへ抜けた」「ウィンドウ外へ出た」「アプリが非アクティブになった」を
        // 区別できないため、HUDのpin判定には使わない（使うとマウスから手を離した状態で
        // HUDが出たまま固定されてしまう）。ポインタ移動は操作通知としてのみ扱う
        .onContinuousHover { phase in
            if case .active = phase { vm.noteUserActivity() }
        }
        .onChange(of: shouldPinHUD, initial: true) { _, pinned in
            vm.setHUDPinned(pinned)
        }
        .onChange(of: vm.isHUDVisible) { _, isVisible in
            // HUDと連動してカーソルも隠す。マウスを動かすとシステムが自動的に復帰させる
            if !isVisible { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        // 写真が切り替わったらズーム/パンを必ずリセットする（スワイプ・矢印キー・シェブロン共通）
        .onChange(of: vm.selectedPhoto?.id) { _, _ in resetZoom() }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            vm.beginHUDSession()
        }
        .onDisappear { vm.endHUDSession() }
        .onKeyPress(.leftArrow)  { vm.noteUserActivity(); vm.selectPrevious(); return .handled }
        .onKeyPress(.rightArrow) { vm.noteUserActivity(); vm.selectNext();     return .handled }
        .onKeyPress(.escape)     { vm.switchToSidebar(); return .handled }
        .onKeyPress(KeyEquivalent("r")) { rotateSelectedPhoto(); return .handled }
        // どのキー入力でもHUDを復帰させる。HUDは非表示中ビュー階層から消えるため
        // Tabでフォーカスを当てて呼び戻すことができず、キーボードのみの操作で
        // HUDへ到達する手段がこれ以外にない
        .onKeyPress(phases: .down) { press in
            vm.noteUserActivity()
            return handleZoomKeyPress(press)
        }
        .toolbar { toolbarItems }
    }

    // MARK: - 写真レイヤー（ズーム/パン/スワイプ）

    private var photoLayer: some View {
        PhotoViewerView(
            photo: vm.selectedPhoto,
            editInfo: vm.currentEditInfo,
            interpolation: isGestureActive ? .medium : .high,
            onDisplayedImageSizeChange: { displayedImagePixelSize = $0 }
        )
        .scaleEffect(effectiveScale)
        .offset(effectiveOffset)
        .clipped()
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size, initial: true) { _, size in
                        viewportSize = size
                    }
            }
        }
        .contentShape(Rectangle())
        .gesture(magnifyGesture)
        .simultaneousGesture(panGesture)
        .onTapGesture(count: 2) { toggleZoom() }
        // トラックパッド2本指スクロールの振り分け。fit倍率（scale <= 1.0）では写真切替の
        // スワイプとして扱い、ズーム中は同じスクロールをパン操作に使う。
        // hitTestがscrollWheel以外でnilを返す設計のため、overlayに重ねてもクリック・
        // ドラッグ・ピンチは下のビューへ完全に透過する
        .overlay {
            TrackpadSwipeCatcher(
                isSwipeEnabled: effectiveScale <= 1.0,
                onSwipeLeft: { vm.noteUserActivity(); vm.selectNext() },
                onSwipeRight: { vm.noteUserActivity(); vm.selectPrevious() },
                onScrollDelta: { delta in panByScroll(delta) }
            )
        }
    }

    // MARK: - HUD

    // 左右ナビゲーションボタン。移動できない側（1枚目/最終枚目）は非表示にする。
    // if分岐でView自体を消すとLiquid Glass（glassEffect）の暗黙コンテナ構成が崩れ、
    // 無関係な他のガラスボタン（回転ボタン等）まで白背景で描画される不具合があったため、
    // Viewは維持したままopacity/disabledで見た目のみ隠す
    private var navigationOverlay: some View {
        HStack {
            NavButton(direction: .prev) { vm.noteUserActivity(); vm.selectPrevious() }
                .focused($focusedHUDControl, equals: .previous)
                .opacity(canGoPrevious ? 1 : 0)
                .disabled(!canGoPrevious)
                .accessibilityHidden(!canGoPrevious)
            Spacer()
            NavButton(direction: .next) { vm.noteUserActivity(); vm.selectNext() }
                .focused($focusedHUDControl, equals: .next)
                .opacity(canGoNext ? 1 : 0)
                .disabled(!canGoNext)
                .accessibilityHidden(!canGoNext)
        }
        .padding(.horizontal, 8)
    }

    // 上部 HUD: お気に入り・回転（左上） / 閉じる（右上）
    private var topHUD: some View {
        VStack {
            HStack(spacing: 14) {
                FavoriteButton(isFavorite: vm.selectedPhoto?.isFavorite ?? false) {
                    vm.noteUserActivity()
                    vm.toggleFavorite()
                }
                .focused($focusedHUDControl, equals: .favorite)

                RotateButton { rotateSelectedPhoto() }
                    .focused($focusedHUDControl, equals: .rotate)

                Spacer()

                CloseButton { vm.switchToSidebar() }
                    .focused($focusedHUDControl, equals: .close)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Spacer()
        }
    }

    // 下部: ページドット + カウンター（お気に入りのみ表示の絞り込みを反映する）
    private var bottomHUD: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                PageDotsView(current: vm.visibleIndex, total: vm.visiblePhotos.count)
                Spacer()
                Text(vm.visibleCounterText)
                    .font(HUDTypography.label)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassOrMaterialCapsule()
                    .padding(.trailing, 14)
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: - 派生値

    // HUDを自動的に隠してはいけない状態。VoiceOver判定はFullscreenViewModel側で
    // 隠す直前に最新値を読むためここには含めない。
    // ツールバー上へポインタを移した場合は、ネイティブのNSToolbarがSwiftUIコンテンツの
    // 外にあり hover が届かないため pin されないが、ツールバーは isToolbarVisible が
    // false になるまで表示が続くうえ、操作すれば noteUserActivity() で即座に復帰する
    private var shouldPinHUD: Bool {
        vm.isModalPresented || focusedHUDControl != nil
    }

    // 絞り込み後に2枚以上ある場合だけ前後ナビゲーションを有効にする
    // （単一写真フォルダではシェブロンをno-opではなく無効表示にして意図を明確にする）
    private var canGoPrevious: Bool {
        guard let index = vm.visibleIndex else { return false }
        return index > 0
    }

    private var canGoNext: Bool {
        guard let index = vm.visibleIndex else { return false }
        return index < vm.visiblePhotos.count - 1
    }

    // ジェスチャー中の暫定値を含む実効ズーム倍率
    private var effectiveScale: CGFloat {
        clampedScale(zoomScale * gestureMagnification)
    }

    // ジェスチャー中の暫定値を含む実効パンオフセット
    private var effectiveOffset: CGSize {
        clampedOffset(
            CGSize(
                width: panOffset.width + gesturePanTranslation.width,
                height: panOffset.height + gesturePanTranslation.height
            ),
            scale: effectiveScale
        )
    }

    // fit表示時の画像サイズ。90度/270度回転時は縦横を入れ替えて計算する
    private var fittedImageSize: CGSize {
        let source = rotationAdjustedPixelSize
        guard source.width > 0, source.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return viewportSize }
        let ratio = min(viewportSize.width / source.width, viewportSize.height / source.height)
        return CGSize(width: source.width * ratio, height: source.height * ratio)
    }

    private var rotationAdjustedPixelSize: CGSize {
        let rotation = vm.currentEditInfo?.rotation ?? 0
        guard rotation % 180 != 0 else { return displayedImagePixelSize }
        return CGSize(width: displayedImagePixelSize.height, height: displayedImagePixelSize.width)
    }

    // 最大ズーム倍率。実際にロード済みの画像がドット等倍になる倍率でキャップし、
    // 768pxサムネイルしか無い状態で過剰に拡大しないようにする（下限は3.0倍）
    private var maxZoomScale: CGFloat {
        let sourceWidth = rotationAdjustedPixelSize.width
        let fitWidth = fittedImageSize.width
        guard sourceWidth > 0, fitWidth > 0 else { return 3.0 }
        return max(3.0, sourceWidth / fitWidth)
    }

    // MARK: - ジェスチャー

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isGestureActive = true
                gestureMagnification = value.magnification
            }
            .onEnded { value in
                zoomScale = clampedScale(zoomScale * value.magnification)
                gestureMagnification = 1.0
                panOffset = clampedOffset(panOffset, scale: zoomScale)
                isGestureActive = false
                vm.noteUserActivity()
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // fit倍率のときはパンさせない（オフセットは常に .zero へクランプされる）
                guard zoomScale > 1.0 else { return }
                isGestureActive = true
                gesturePanTranslation = value.translation
            }
            .onEnded { value in
                defer {
                    gesturePanTranslation = .zero
                    isGestureActive = false
                }
                guard zoomScale > 1.0 else { return }
                let moved = CGSize(
                    width: panOffset.width + value.translation.width,
                    height: panOffset.height + value.translation.height
                )
                panOffset = clampedOffset(moved, scale: zoomScale)
                vm.noteUserActivity()
            }
    }

    // ズーム中の2本指スクロールによるパン。スワイプ判定と違い閾値コミットは不要で、
    // 受け取ったデルタを都度クランプしながら反映する
    private func panByScroll(_ delta: CGSize) {
        guard zoomScale > 1.0 else { return }
        let moved = CGSize(
            width: panOffset.width + delta.width,
            height: panOffset.height + delta.height
        )
        panOffset = clampedOffset(moved, scale: zoomScale)
        vm.noteUserActivity()
    }

    // MARK: - 操作

    private func rotateSelectedPhoto() {
        vm.noteUserActivity()
        vm.rotateSelectedPhoto()
        // 回転でfit時の表示サイズが変わるため、ズーム/パンの蓄積量をリセットする
        resetZoom()
    }

    private func resetZoom() {
        zoomScale = 1.0
        gestureMagnification = 1.0
        panOffset = .zero
        gesturePanTranslation = .zero
    }

    private func toggleZoom() {
        vm.noteUserActivity()
        if zoomScale > 1.0 {
            resetZoom()
        } else {
            zoomScale = clampedScale(doubleClickZoomScale)
            panOffset = .zero
        }
    }

    private func applyZoom(_ scale: CGFloat) {
        vm.noteUserActivity()
        zoomScale = clampedScale(scale)
        panOffset = clampedOffset(panOffset, scale: zoomScale)
    }

    // ⌘+ / ⌘- / ⌘0 のズーム操作。ピンチ非対応デバイス（Magic Mouse等）の代替手段
    private func handleZoomKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        switch press.characters {
        case "+", "=":
            applyZoom(zoomScale * keyboardZoomStep)
            return .handled
        case "-":
            applyZoom(zoomScale / keyboardZoomStep)
            return .handled
        case "0":
            vm.noteUserActivity()
            resetZoom()
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - クランプ

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 1.0), maxZoomScale)
    }

    // 拡大後の画像が画面外へ流れないよう、各軸のはみ出し量の半分を上限にする。
    // fit倍率以下のときはパンを許可しない
    private func clampedOffset(_ offset: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1.0 else { return .zero }
        let displayed = fittedImageSize
        let scaledWidth = displayed.width * scale
        let scaledHeight = displayed.height * scale
        let maxX = max(0, (scaledWidth - viewportSize.width) / 2)
        let maxY = max(0, (scaledHeight - viewportSize.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
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
                .frame(width: 44, height: 44)
                .glassOrMaterialCircle()
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .accessibilityLabel(isFavorite ? "お気に入りを解除" : "お気に入りに追加")
    }
}

// SlideshowModeView の回転ボタンとスタイル・ラベルを揃える
private struct RotateButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "rotate.right")
                .foregroundStyle(Color.onDarkCanvasSecondary)
                .frame(width: 44, height: 44)
                .glassOrMaterialCircle()
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .help("右に90度回転 (R)")
        .accessibilityLabel("写真を右に90度回転")
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.onDarkCanvasSecondary)
                .frame(width: 44, height: 44)
                .glassOrMaterialCircle()
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .accessibilityLabel("サイドバーに戻る")
    }
}
