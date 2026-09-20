import AppKit
import SwiftUI

private struct ZoomPanTransientState: Equatable {
    var zoomScale: CGFloat = 1.0
    var gestureMagnification: CGFloat = 1.0
    var panOffset: CGSize = .zero
    var gesturePanTranslation: CGSize = .zero
}

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
    @State private var zoomPanState = ZoomPanTransientState()
    @State private var isGestureActive = false

    // ズーム上限・パンのクランプ計算に使う実測値
    @State private var viewportSize: CGSize = .zero
    @State private var displayedImagePixelSize: CGSize = .zero

    // HUD内のフォーカス対象
    private enum HUDControl: Hashable {
        case previous, next, favorite, rotate, upscale, info, close
    }

    // ダブルクリック時に切り替えるズーム倍率
    private let doubleClickZoomScale: CGFloat = 2.0
    // キーボードショートカット1回あたりのズーム変化量
    private let keyboardZoomStep: CGFloat = 1.25

    var body: some View {
        ZStack {
            Color.viewerCanvas.ignoresSafeArea()

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
            neighborPrefetchURLs: neighborPrefetchURLs,
            fileAttributesSnapshots: vm.content.fileAttributesSnapshots,
            prefersFullSizeDecode: prefersFullSizeDecode,
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
        .padding(.horizontal, 24)
    }

    // 上部 HUD: ズーム表示（左上） / お気に入り・回転・超解像・インスペクタ・閉じるのグラスクラスタ（右上）
    private var topHUD: some View {
        VStack {
            HStack {
                if vm.selectedPhoto != nil {
                    zoomIndicatorCapsule
                }
                Spacer()
                topRightControlCluster
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Spacer()
        }
    }

    // 右上のグラスクラスタ本体（お気に入り・回転・超解像・インスペクタ表示 / 閉じる）
    private var topRightControlClusterContent: some View {
        HStack(spacing: 2) {
            HUDClusterButton(
                systemImage: vm.selectedPhoto?.isFavorite == true ? "star.fill" : "star",
                tint: vm.selectedPhoto?.isFavorite == true ? Color.yellow : Color.onViewerCanvasSecondary,
                accessibilityLabel: vm.selectedPhoto?.isFavorite == true ? "viewer.favorite.remove" : "viewer.favorite.add"
            ) {
                vm.noteUserActivity()
                vm.toggleFavorite()
            }
            .focused($focusedHUDControl, equals: .favorite)

            HUDClusterButton(systemImage: "rotate.right", accessibilityLabel: "a11y.toolbar.rotate") {
                rotateSelectedPhoto()
            }
            .help("toolbar.rotate.help")
            .focused($focusedHUDControl, equals: .rotate)

            HUDClusterButton(systemImage: "wand.and.sparkles", accessibilityLabel: "a11y.toolbar.upscale") {
                vm.noteUserActivity()
                vm.presentUpscaleExport()
            }
            .help("toolbar.upscale.help")
            .focused($focusedHUDControl, equals: .upscale)

            HUDClusterButton(systemImage: "info.circle", accessibilityLabel: "viewer.showInspector") {
                showInspectorInSidebar()
            }
            .focused($focusedHUDControl, equals: .info)

            Divider()
                .frame(width: 1, height: 18)

            HUDClusterButton(systemImage: "xmark", accessibilityLabel: "viewer.backToSidebar") {
                vm.switchToSidebar()
            }
            .focused($focusedHUDControl, equals: .close)
        }
    }

    @ViewBuilder
    private var topRightControlCluster: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer {
                topRightControlClusterContent
                    .glassEffect(in: Capsule())
            }
        } else {
            topRightControlClusterContent
                .glassOrMaterialCapsule()
        }
    }

    // 左上のズーム表示（fit表示の実寸%、またはズーム後の実寸%）
    private var zoomIndicatorCapsule: some View {
        zoomIndicatorLabel
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .glassOrMaterialCapsule()
    }

    @ViewBuilder
    private var zoomIndicatorLabel: some View {
        if isZoomFit {
            if let fitDisplayPercent {
                Text("viewer.zoom.fitPercent \(fitDisplayPercent)")
            } else {
                Text("viewer.zoom.fit")
            }
        } else {
            Text("viewer.zoom.percent \(currentDisplayPercent)")
        }
    }

    // 下部: 左=EXIFキャプション / 中央=ページドット+カウンターのグラスカプセル
    // （お気に入りのみ表示の絞り込みを反映する）
    private var bottomHUD: some View {
        VStack {
            Spacer()
            ZStack {
                HStack {
                    Spacer()
                    bottomCenterCapsule
                    Spacer()
                }
                HStack {
                    if let exifCaption {
                        EXIFCaptionCapsule(content: exifCaption)
                            .padding(.leading, 14)
                    }
                    Spacer()
                }
            }
            .padding(.bottom, 10)
        }
    }

    /// 位置が特定できないとき（絞り込みで選択写真が非表示など）は表示文字列をそのまま読む。
    private var counterAccessibilityLabel: Text {
        if let index = vm.visibleIndex {
            return Text("a11y.viewer.position \(index + 1) \(vm.visiblePhotos.count)")
        }
        return Text(vm.visibleCounterText)
    }

    private var bottomCenterCapsule: some View {
        HStack(spacing: 12) {
            PageDotsView(current: vm.visibleIndex, total: vm.visiblePhotos.count)
            Text(vm.visibleCounterText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.primary)
                // "3 / 12" のスラッシュ表記は VoiceOver に伝わらないため文で読ませる
                .accessibilityLabel(counterAccessibilityLabel)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glassOrMaterialCapsule()
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

    // 先読み対象（前後1枚）。フルスクリーンは selectNext/selectPrevious とも端でクランプされ
    // ループしないため、wrapsAround は指定しない
    private var neighborPrefetchURLs: [URL] {
        HighResPrefetcher.neighborURLs(in: vm.visiblePhotos, around: vm.visibleIndex)
    }

    // 表示中の画像をフルサイズで再デコードすべきズーム倍率。
    // 通常表示は表示領域サイズに合わせてダウンサンプルしており、fit表示の1.5倍を超えると
    // 拡大時にデコード解像度が不足するため、ここから元解像度へ切り替える
    // （45MP級のRAWで最大ズーム時に眠くなるのを防ぐ）
    private static let fullSizeDecodeZoomThreshold: CGFloat = 1.5

    // ジェスチャー中の一時倍率も含めて判定する。PhotoViewerView 側でデバウンスするため、
    // ピンチ中にしきい値を出入りしても再デコードは連発しない
    private var prefersFullSizeDecode: Bool {
        effectiveScale > Self.fullSizeDecodeZoomThreshold
    }

    // ジェスチャー中の一時値を含む実効ズーム倍率
    private var effectiveScale: CGFloat {
        clampedScale(zoomPanState.zoomScale * zoomPanState.gestureMagnification)
    }

    // ジェスチャー中の一時値を含む実効パンオフセット
    private var effectiveOffset: CGSize {
        clampedOffset(
            CGSize(
                width: zoomPanState.panOffset.width + zoomPanState.gesturePanTranslation.width,
                height: zoomPanState.panOffset.height + zoomPanState.gesturePanTranslation.height
            ),
            scale: effectiveScale
        )
    }

    // fit表示時の画像サイズ。90度/270度回転時は縦横を入れ替えて計算する
    private var fittedImageSize: CGSize {
        ZoomPanGeometry.fittedImageSize(
            sourcePixelSize: rotationAdjustedPixelSize,
            viewportSize: viewportSize
        )
    }

    private var rotationAdjustedPixelSize: CGSize {
        ZoomPanGeometry.rotationAdjustedPixelSize(
            displayedImagePixelSize,
            rotation: vm.currentEditInfo?.rotation ?? 0
        )
    }

    private var maxZoomScale: CGFloat {
        ZoomPanGeometry.maxZoomScale(
            sourcePixelSize: rotationAdjustedPixelSize,
            fittedImageSize: fittedImageSize
        )
    }

    // fit倍率（ズーム操作前の初期表示）かどうか。ZoomPanGeometry.minScaleがfitの下限＝基準値のため、
    // 実効スケールがそれ以下ならfit表示中とみなす
    private var isZoomFit: Bool {
        effectiveScale <= ZoomPanGeometry.minScale
    }

    // fit表示時、実寸(100%)に対して何%で表示されているか。画像の実ピクセルサイズが
    // まだ判明していない場合（表示直後等）はnilを返し、パーセント無しの表示にフォールバックする
    private var fitDisplayPercent: Int? {
        guard rotationAdjustedPixelSize.width > 0, fittedImageSize.width > 0 else { return nil }
        return Int(((fittedImageSize.width / rotationAdjustedPixelSize.width) * 100).rounded())
    }

    // 現在の実効ズーム倍率を、実寸(100%)基準のパーセントに変換したもの
    private var currentDisplayPercent: Int {
        guard let fitDisplayPercent else {
            return Int((effectiveScale * 100).rounded())
        }
        return Int((CGFloat(fitDisplayPercent) * effectiveScale).rounded())
    }

    // 下部左のEXIFキャプション表示内容。EXIF未取得の写真では表示しない
    private var exifCaption: EXIFCaptionContent? {
        guard let photo = vm.selectedPhoto, photo.exifFetchedAt != nil else { return nil }
        let panelVM = EXIFPanelViewModel(photo: photo)

        // アパーチャ・ISOはEXIFパネルの表示（ラベル併記前提の書式）と異なり、
        // ラベル無しの短い書式（f/8, ISO 100）が必要なためここで組み立てる。
        // シャッタースピード・焦点距離はEXIFパネルと同じ書式で問題ないため流用する
        var segments: [String] = []
        if let aperture = photo.aperture {
            segments.append("f/" + aperture.formatted(.number.precision(.fractionLength(1)).grouping(.never)))
        }
        if let shutterSpeedText = panelVM.shutterSpeedText {
            segments.append(shutterSpeedText)
        }
        if let iso = photo.iso {
            segments.append("ISO \(iso)")
        }
        if let focalLengthText = panelVM.focalLengthText {
            segments.append(focalLengthText)
        }

        return EXIFCaptionContent(
            fileName: panelVM.fileNameText ?? "",
            summary: segments.joined(separator: " · "),
            cameraModel: panelVM.cameraModelText
        )
    }

    // MARK: - ジェスチャー

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isGestureActive = true
                zoomPanState.gestureMagnification = value.magnification
            }
            .onEnded { value in
                zoomPanState.zoomScale = clampedScale(zoomPanState.zoomScale * value.magnification)
                zoomPanState.gestureMagnification = 1.0
                zoomPanState.panOffset = clampedOffset(zoomPanState.panOffset, scale: zoomPanState.zoomScale)
                isGestureActive = false
                vm.noteUserActivity()
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // fit倍率のときはパンさせない（オフセットは常に .zero へクランプされる）
                guard zoomPanState.zoomScale > 1.0 else { return }
                isGestureActive = true
                zoomPanState.gesturePanTranslation = value.translation
            }
            .onEnded { value in
                defer {
                    zoomPanState.gesturePanTranslation = .zero
                    isGestureActive = false
                }
                guard zoomPanState.zoomScale > 1.0 else { return }
                let moved = CGSize(
                    width: zoomPanState.panOffset.width + value.translation.width,
                    height: zoomPanState.panOffset.height + value.translation.height
                )
                zoomPanState.panOffset = clampedOffset(moved, scale: zoomPanState.zoomScale)
                vm.noteUserActivity()
            }
    }

    // ズーム中の2本指スクロールによるパン。スワイプ判定と違い閾値コミットは不要で、
    // 受け取ったデルタを都度クランプしながら反映する
    private func panByScroll(_ delta: CGSize) {
        guard zoomPanState.zoomScale > 1.0 else { return }
        let moved = CGSize(
            width: zoomPanState.panOffset.width + delta.width,
            height: zoomPanState.panOffset.height + delta.height
        )
        zoomPanState.panOffset = clampedOffset(moved, scale: zoomPanState.zoomScale)
        vm.noteUserActivity()
    }

    // MARK: - 操作

    private func rotateSelectedPhoto() {
        vm.noteUserActivity()
        vm.rotateSelectedPhoto()
        // 回転でfit時の表示サイズが変わるため、ズーム/パンの蓄積量をリセットする
        resetZoom()
    }

    // インスペクタ付きのサイドバーモードへ戻る（右上クラスタのinfoボタン用）
    private func showInspectorInSidebar() {
        vm.noteUserActivity()
        vm.content.isInspectorVisible = true
        vm.switchToSidebar()
    }

    private func resetZoom() {
        zoomPanState = ZoomPanTransientState()
    }

    private func toggleZoom() {
        vm.noteUserActivity()
        if zoomPanState.zoomScale > 1.0 {
            resetZoom()
        } else {
            zoomPanState.zoomScale = clampedScale(doubleClickZoomScale)
            zoomPanState.panOffset = .zero
        }
    }

    private func applyZoom(_ scale: CGFloat) {
        vm.noteUserActivity()
        zoomPanState.zoomScale = clampedScale(scale)
        zoomPanState.panOffset = clampedOffset(zoomPanState.panOffset, scale: zoomPanState.zoomScale)
    }

    // ⌘+ / ⌘- / ⌘0 のズーム操作。ピンチ非対応デバイス（Magic Mouse等）の代替手段
    private func handleZoomKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        switch press.characters {
        case "+", "=":
            applyZoom(zoomPanState.zoomScale * keyboardZoomStep)
            return .handled
        case "-":
            applyZoom(zoomPanState.zoomScale / keyboardZoomStep)
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

    // 計算本体はZoomPanGeometryへ切り出し、ここでは現在の@Stateを引数として渡す
    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        ZoomPanGeometry.clampedScale(scale, maxScale: maxZoomScale)
    }

    private func clampedOffset(_ offset: CGSize, scale: CGFloat) -> CGSize {
        ZoomPanGeometry.clampedOffset(
            offset,
            scale: scale,
            fittedImageSize: fittedImageSize,
            viewportSize: viewportSize
        )
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

private struct NavButton: View {
    enum Direction { case prev, next }
    let direction: Direction
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .prev ? "chevron.left" : "chevron.right")
                .foregroundStyle(Color.onViewerCanvas)
                .frame(width: 44, height: 44)
                .glassOrMaterialCircle()
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.control))
        .accessibilityLabel(direction == .prev ? "viewer.previousPhoto" : "viewer.nextPhoto")
    }
}

// 右上グラスクラスタ内のアイコンボタン。背景はクラスタ全体（capsule）が担うため、
// 個々のボタンは円形グラスを持たない（NavButton等とは異なる）
private struct HUDClusterButton: View {
    let systemImage: String
    var tint: Color = Color.onViewerCanvasSecondary
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 40, height: 36)
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .accessibilityLabel(accessibilityLabel)
    }
}

// 下部左のEXIFキャプション表示内容
private struct EXIFCaptionContent {
    let fileName: String
    // "f/8 · 1/250 s · ISO 100 · 35 mm" 形式（欠損する項目は自動的に省かれる）
    let summary: String
    let cameraModel: String?
}

private struct EXIFCaptionCapsule: View {
    let content: EXIFCaptionContent

    var body: some View {
        HStack(spacing: 8) {
            Text(content.fileName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            if !content.summary.isEmpty {
                CaptionSeparator()
                Text(content.summary)
                    .font(.caption)
                    .monospacedDigit()
            }

            if let cameraModel = content.cameraModel, !cameraModel.isEmpty {
                CaptionSeparator()
                Text(cameraModel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glassOrMaterialCapsule()
        .accessibilityElement(children: .combine)
    }
}

private struct CaptionSeparator: View {
    var body: some View {
        Divider()
            .frame(width: 1, height: 12)
    }
}
