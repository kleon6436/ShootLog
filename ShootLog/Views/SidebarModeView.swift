import AppKit
import SwiftUI

// サイドバーモード。左=写真一覧 / 右=ビューア の標準2カラム構成に、
// EXIFパネルを標準インスペクタ（`.inspector`）として付与する。
// 信号機の位置連動はmacOS標準のNavigationSplitView + NSToolbarに委ね、
// サイドバートグルはOS標準ボタンを外した上で .navigation 配置の独自ボタン1つに統一する
// （.navigation 配置なのでサイドバー境界に追従して位置が変わり、Xcode 同様の連動になる）。
struct SidebarModeView: View {
    @Bindable var vm: SidebarViewModel
    // サイドバー幅（Capture One風に可変・次回起動時の初期幅として近似復元する）
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 140
    @AppStorage("sidebarColumnVisibility") private var storedColumnVisibility: String = SidebarViewModel.ColumnVisibilityState.visible.rawValue
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isSidebarFocused: Bool
    // サイドバー（左カラム）の表示状態。標準トグルボタン・ドラッグ収縮・メニューコマンドで可変に制御する
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            photoListColumn
        } detail: {
            viewerColumn
        }
        .searchable(text: $vm.searchText, placement: .sidebar, prompt: Text(searchPrompt))
        .toolbar { toolbarItems }
        .overlay(alignment: .bottom) {
            // トースト（お気に入り登録など）
            if let toast = vm.toastMessage {
                ToastView(message: toast)
                    .padding(.bottom, toastBottomInset)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.toastMessage)
        .onAppear(perform: restoreColumnVisibility)
        .onChange(of: columnVisibility) { _, newValue in
            storedColumnVisibility = vm.syncColumnVisibility(SidebarViewModel.ColumnVisibilityState(newValue))
        }
        .onChange(of: vm.sidebarToggleRequestID) { _, _ in
            toggleSidebar()
        }
        .onChange(of: vm.inspectorToggleRequestID) { _, _ in
            toggleInspector()
        }
        // selectedPhotoのsetterが次のMainActorサイクルで
        // ContentViewModel.selectPhotoを呼び、EditInfo/EXIF遅延ロードも行うため、
        // ここでの再ロードは不要（二重実行防止）
    }

    // MARK: - Columns

    // 左: 写真一覧（最小 120pt、理想 sidebarWidth pt、最大 400pt）。
    // 背景・区切り線は標準サイドバーの材質に任せる
    private var photoListColumn: some View {
        PhotoListView(
            photos: vm.displayedPhotos,
            selection: $vm.selectedPhoto,
            contextMenuActions: photoContextMenuActions
        )
            .navigationSplitViewColumnWidth(min: 120, ideal: sidebarWidth, max: 400)
            // OS標準のサイドバートグルは表示中だけ現れて独自ボタンと二重に並ぶため明示的に外し、
            // 常時表示の独自トグル1つに統一する（この modifier はサイドバー列の根に付ける必要がある）
            .toolbar(removing: .sidebarToggle)
            .background {
                // NavigationSplitView はドラッグ後の実幅を読み取る公開APIを持たないため、
                // GeometryReaderで描画幅を観測しデバウンスして近似的に永続化する
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size.width) { _, newWidth in
                            vm.scheduleWidthSave(newWidth, current: $sidebarWidth)
                        }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isSidebarFocused)
            .onAppear { isSidebarFocused = true }
            .onKeyPress(.upArrow)   { vm.selectPrevious(); return .handled }
            .onKeyPress(.downArrow) { vm.selectNext();     return .handled }
            .overlay(alignment: .bottom) {
                if vm.isLoading {
                    ProgressView("common.loading")
                        .padding(Spacing.medium)
                        .glassOrMaterial(cornerRadius: CornerRadius.medium)
                        .padding(.bottom, Spacing.medium)
                } else {
                    let messages = [
                        vm.previewGenerationRemaining > 0
                            ? String(
                                format: String(localized: "develop.previewGeneration.progress"),
                                Int64(vm.previewGenerationRemaining)
                            )
                            : nil,
                        vm.aiLabelingRemaining > 0
                            ? String(
                                format: String(localized: "sidebar.aiLabelingProgress"),
                                Int64(vm.aiLabelingRemaining)
                            )
                            : nil,
                        vm.aiQualityDiagnosisRemaining > 0
                            ? String(
                                format: String(localized: "sidebar.aiQualityDiagnosisProgress"),
                                Int64(vm.aiQualityDiagnosisRemaining)
                            )
                            : nil,
                        vm.exifPrefetchRemaining > 0
                            ? String(
                                format: String(localized: "sidebar.exifPrefetchProgress"),
                                Int64(vm.exifPrefetchRemaining)
                            )
                            : nil
                    ].compactMap { $0 }
                    if !messages.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            ForEach(messages, id: \.self) { message in
                                ProgressView(message)
                            }
                        }
                        .padding(Spacing.medium)
                        .glassOrMaterial(cornerRadius: CornerRadius.medium)
                        .padding(.bottom, Spacing.medium)
                    }
                }
            }
    }

    // 右: ビューア（黒背景）+ 編集ツールバー。EXIFパネルは標準インスペクタとして付与する
    private var viewerColumn: some View {
        EditablePhotoView(
            photo: vm.selectedPhoto,
            editInfo: vm.currentEditInfo,
            isCropMode: vm.isCropMode,
            developViewModel: vm.developViewModel,
            neighborPrefetchURLs: neighborPrefetchURLs,
            fileAttributesSnapshots: vm.content.fileAttributesSnapshots,
            onCropApply: { rect in vm.setCropRect(rect) },
            onCropCancel: { vm.isCropMode = false }
        )
        .background(Color.viewerCanvas)
        // 編集ツールバーはビューア下端の中央。右下だと写真の右下隅と重なりやすく、
        // 中央下は macOS 標準のフローティングコントロール（写真.app等）と同じ置き方になる
        .overlay(alignment: .bottom) {
            if vm.selectedPhoto != nil {
                EditorToolbarView(
                    editInfo: vm.currentEditInfo,
                    isCropMode: vm.isCropMode,
                    isFavorite: vm.isSelectedPhotoFavorite,
                    isDevelopActive: vm.isEXIFPanelVisible && vm.inspectorTab == .develop,
                    isPhotosLibraryPhoto: selectedPhotoAvailability.map { !$0.hasLocalOriginalFile } ?? false,
                    onRotate: { vm.rotateSelectedPhoto() },
                    onToggleCrop: { vm.toggleCropMode() },
                    onToggleFavorite: { vm.toggleFavorite() },
                    onEditDevelop: { vm.showDevelopPanel() },
                    onReset: { vm.resetEdits() },
                    onUpscale: { vm.presentUpscaleExport() }
                )
            }
        }
        // 表示位置（何枚中の何枚目か）はビューア右上。編集ツールバーと上下で役割を分ける
        .overlay(alignment: .topTrailing) {
            if vm.selectedPhoto != nil {
                CounterBadge(text: vm.visibleCounterText, font: .caption)
                    .accessibilityLabel(positionAccessibilityLabel)
                    .padding(.top, 14)
                    .padding(.trailing, 16)
            }
        }
        .inspector(isPresented: $vm.isEXIFPanelVisible) {
            InspectorTabContainer(
                sidebarViewModel: vm,
                photo: vm.selectedPhoto,
                onToggleTag: { tag in
                    guard let photo = vm.selectedPhoto else { return }
                    vm.toggleSuccessTag(tag, for: photo)
                }
            )
            // 編集タブはトーンカーブ・HSL のため広めに取る
            .inspectorColumnWidth(
                min: vm.inspectorTab == .develop ? 260 : 240,
                ideal: vm.inspectorTab == .develop ? 300 : 300,
                max: vm.inspectorTab == .develop ? 420 : 400
            )
        }
        // ウィンドウタイトル＝開いている写真ソース、サブタイトル＝その枚数。
        // NavigationSplitView では詳細側に付けたタイトルがウィンドウタイトルになる
        .navigationTitle(Text(verbatim: windowTitle))
        .navigationSubtitle(windowSubtitle)
    }

    // MARK: - ウィンドウタイトル

    private var windowTitle: String {
        switch vm.content.currentPhotoSource {
        case .folder(let url):
            url.lastPathComponent
        case .photosLibrary:
            String(localized: "toolbar.title.photosLibrary")
        case nil:
            // アプリ名は固有名詞のためローカライズ対象にしない
            "ShootLog"
        }
    }

    // 写真ソース未選択のときはサブタイトルを出さない（「0枚」を見せても情報にならない）
    private var windowSubtitle: Text {
        guard vm.content.currentPhotoSource != nil else { return Text(verbatim: "") }
        return Text("toolbar.subtitle.photoCount \(vm.photos.count)")
    }

    // VoiceOver では「3 / 12」のスラッシュが意味を成さないため、位置と総数を文章で読み上げる。
    // 絞り込みで選択中写真が一覧から外れている間は位置を偽らず、表示そのまま（—）を読ませる
    private var positionAccessibilityLabel: Text {
        guard let index = vm.visibleIndex else { return Text(verbatim: vm.visibleCounterText) }
        return Text("a11y.viewer.position \(index + 1) \(vm.visiblePhotos.count)")
    }

    // トーストがビューア下端中央の編集ツールバーと重ならないよう、表示中はその上へ退避させる。
    // 内訳: ボタン高さ32 + 上下余白8 + 下端余白20 + 間隔12
    private var toastBottomInset: CGFloat {
        vm.selectedPhoto != nil ? 72 : 20
    }

    // 選択中写真に対する操作可否。外部アプリ一覧の照会（Launch Services）はここでは不要なので
    // hasExternalApps は既定値のままにする
    private var selectedPhotoAvailability: PhotoActionAvailability? {
        vm.selectedPhoto.map { PhotoActionAvailability(photo: $0) }
    }

    // 先読み対象（前後1枚）。上下矢印キーでの写真送り（vm.selectNext / selectPrevious）は
    // visiblePhotos 基準かつ端でクランプしループしないため、wrapsAround は指定しない
    private var neighborPrefetchURLs: [URL] {
        HighResPrefetcher.neighborURLs(in: vm.visiblePhotos, around: vm.visibleIndex)
    }

    // MARK: - Toolbar

    // トグルボタンのヘルプ・アクセシビリティ文言の出し分け用
    private var isSidebarShown: Bool {
        columnVisibility != .detailOnly
    }

    private var searchPrompt: LocalizedStringResource {
        if #available(macOS 27, *) {
            "sidebar.search.prompt.aiEnabled"
        } else {
            "sidebar.search.prompt.fileNameOnly"
        }
    }

    // 標準ツールバーの中身。
    // サイドバートグルは OS 標準ボタンを外して独自ボタン1つに統一しているため常時表示する。
    // 配置は Xcode 同様の位置連動を得るため .navigation（サイドバー領域の先頭）とし、
    // 「フォルダを開く」まで含めて1クラスタにする。末尾側は役割ごとに
    // 「表示モード」「絞り込み」「その他の操作」の3クラスタへ分け、
    // macOS 26 では ToolbarSpacer(.fixed) で明示的に離してガラスのまとまりを分ける
    // （macOS 15 では区切りが入らず同じ順序で素直に並ぶ）
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
            }
            .help(isSidebarShown ? "sidebar.toggle.hide.help" : "sidebar.toggle.show.help")
            .accessibilityLabel(isSidebarShown ? "sidebar.toggle.hide" : "sidebar.toggle.show")

            Button { vm.openFolder() } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("toolbar.openFolder.help")
            .accessibilityLabel("common.openFolder")
        }

        // クラスタA: 表示モード切替（セグメント）
        ToolbarItemGroup(placement: .primaryAction) {
            ModeTogglePicker(currentModeID: $vm.currentModeID, modes: vm.availableModes)
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // クラスタB: 一覧の絞り込み（お気に入り・AIカテゴリ）
        ToolbarItemGroup(placement: .primaryAction) {
            FavoritesOnlyToggleButton(
                showFavoritesOnly: $vm.showFavoritesOnly,
                isDisabled: vm.photos.isEmpty
            )

            AICategoryFilterMenu(
                selectedCategories: $vm.selectedAICategories,
                availableCategories: vm.availableAICategories,
                isDisabled: vm.photos.isEmpty
            )
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // クラスタC: 分析・外部アプリ・設定。
        // 「フォルダを開く」は.navigationクラスタに持つため、共有グループには渡さない
        ViewerToolbarTrailingGroup(
            isPhotosEmpty: vm.photos.isEmpty,
            hasSelectedPhoto: vm.selectedPhoto != nil,
            externalApps: vm.externalApps,
            openAnalysis: { vm.openAnalysis() },
            openInExternalApp: { adapter in vm.openInExternalApp(adapter) },
            openSettings: { openSettings() }
        )

        // EXIFトグルはXcodeのインスペクタボタン同様、他アクションから切り離した
        // 単独グループとしてツールバー末尾（＝ウィンドウ右端）に固定表示する。
        // 左サイドバートグル（.navigation配置）と異なり、サイドバー境界にもEXIFパネルの
        // 開閉状態にも追従させず、常に同じ位置に置く。
        // 連続する ToolbarItemGroup は隙間なく詰めて描画されるため、
        // macOS 26 以降は ToolbarSpacer で明示的に離す（Xcodeと同じ見た目の分離）
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: toggleInspector) {
                Image(systemName: "sidebar.right")
            }
            .help(vm.isEXIFPanelVisible ? "inspector.toggle.hide.help" : "inspector.toggle.show.help")
            .accessibilityLabel(vm.isEXIFPanelVisible ? "inspector.toggle.hide" : "inspector.toggle.show")
        }
    }

    // MARK: - Actions

    private func restoreColumnVisibility() {
        columnVisibility = vm.restoreColumnVisibility(from: storedColumnVisibility).navigationVisibility
    }

    // メニューコマンド（⌘\）とツールバーのトグルボタン用。
    // NSSplitView が畳まれた状態からは columnVisibility への代入だけでは開き直せないため、
    // まず AppKit の toggleSidebar(_:) を試す。
    // AppKit 経由で折りたたんだ場合に SwiftUI 側のバインディングが更新されない環境があり、
    // その状態を放置すると AppStorage への永続化・vm.setSidebarVisible・メニュー文言が
    // 実際の表示状態とずれるため、AppKit の実状態から求めた期待値を必ず columnVisibility にも反映する。
    // AppKit の NSViewController 走査・実行自体はView層の責務として残し、
    // 「トグル後どちらの表示状態にすべきか」の判定のみ vm に委譲する
    private func toggleSidebar() {
        let selector = #selector(NSSplitViewController.toggleSidebar(_:))
        let window = NSApp.keyWindow ?? NSApp.mainWindow

        // ドラッグで畳まれた場合など columnVisibility が古い可能性があるため、
        // トグル前の実状態（AppKit 側）を基準に反転後の期待値を決める
        let wasCollapsed = sidebarSplitViewItem(in: window)?.isCollapsed ?? (columnVisibility == .detailOnly)
        let target = vm.resolveSidebarToggleTarget(wasCollapsed: wasCollapsed).navigationVisibility

        let performedByAppKit = window?.firstResponder?.tryToPerform(selector, with: nil) == true
            || window?.contentViewController?.tryToPerform(selector, with: nil) == true

        if performedByAppKit {
            // AppKit 側で既にアニメーションが走っているため、ここでは状態同期のみ行う
            if columnVisibility != target {
                columnVisibility = target
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = target
        }
    }

    // ウィンドウの ViewController 階層から「サイドバー」挙動を持つ NSSplitViewItem を探す。
    // SwiftUI の NavigationSplitView は内部で NSSplitViewController を使うため、
    // サイドバーが実際に畳まれているかはここから読み取れる（見つからない場合は nil）
    private func sidebarSplitViewItem(in window: NSWindow?) -> NSSplitViewItem? {
        guard let root = window?.contentViewController else { return nil }

        var pending: [NSViewController] = [root]
        while let controller = pending.first {
            pending.removeFirst()
            if let splitController = controller as? NSSplitViewController,
               let sidebarItem = splitController.splitViewItems.first(where: { $0.behavior == .sidebar }) {
                return sidebarItem
            }
            pending.append(contentsOf: controller.children)
        }
        return nil
    }

    // isEXIFPanelVisible は ContentViewModel.isInspectorVisible に委譲されているため
    // ここでのトグルだけでメニュー文言（FocusedValue）も同期する
    private func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.2)) {
            vm.isEXIFPanelVisible.toggle()
        }
    }
}

// MARK: - Toolbar Components
// ModeTogglePicker / ExternalAppMenu は Core/Shared/UI/ModeToolbarComponents.swift に
// 共通部品として切り出し、fullscreen/slideshowモードの標準ツールバーとも共有する
