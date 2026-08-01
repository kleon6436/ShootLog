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
        .toolbar { toolbarItems }
        .overlay(alignment: .bottom) {
            // トースト（お気に入り登録など）
            if let toast = vm.toastMessage {
                ToastView(message: toast)
                    .padding(.bottom, 20)
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
        // selectedPhotoのsetter（SidebarViewModel経由でContentViewModel.selectPhoto）が
        // EditInfo/EXIF遅延ロードを既に行うため、ここでの再ロードは不要（二重実行防止）
    }

    // MARK: - Columns

    // 左: 写真一覧（最小 120pt、理想 sidebarWidth pt、最大 400pt）。
    // 背景・区切り線は標準サイドバーの材質に任せる
    private var photoListColumn: some View {
        PhotoListView(photos: vm.displayedPhotos, selection: $vm.selectedPhoto)
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
                    ProgressView("読み込み中…")
                        .padding(Spacing.medium)
                        .glassOrMaterial(cornerRadius: CornerRadius.medium)
                        .padding(.bottom, Spacing.medium)
                }
            }
    }

    // 右: ビューア（黒背景）+ 編集ツールバー。EXIFパネルは標準インスペクタとして付与する
    private var viewerColumn: some View {
        EditablePhotoView(
            photo: vm.selectedPhoto,
            editInfo: vm.currentEditInfo,
            isCropMode: vm.isCropMode,
            onCropApply: { rect in vm.setCropRect(rect) },
            onCropCancel: { vm.isCropMode = false }
        )
        .background(.black)
        .overlay(alignment: .bottomTrailing) {
            if vm.selectedPhoto != nil {
                EditorToolbarView(
                    editInfo: vm.currentEditInfo,
                    isCropMode: vm.isCropMode,
                    isFavorite: vm.isSelectedPhotoFavorite,
                    onRotate: { vm.rotateSelectedPhoto() },
                    onToggleCrop: { vm.toggleCropMode() },
                    onToggleFavorite: { vm.toggleFavorite() },
                    onReset: { vm.resetEdits() }
                )
            }
        }
        .inspector(isPresented: $vm.isEXIFPanelVisible) {
            EXIFPanelView(photo: vm.selectedPhoto)
                .inspectorColumnWidth(min: 180, ideal: 200, max: 300)
        }
    }

    // MARK: - Toolbar

    // トグルボタンのヘルプ・アクセシビリティ文言の出し分け用
    private var isSidebarShown: Bool {
        columnVisibility != .detailOnly
    }

    // 標準ツールバーの中身。
    // サイドバートグルは OS 標準ボタンを外して独自ボタン1つに統一しているため常時表示する。
    // 配置は Xcode 同様の位置連動を得るため .navigation（サイドバー領域の先頭）とし、
    // フォルダを開くボタンをその右隣の独立ボタンとして続け、他のアイテムは .primaryAction に置く
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
            }
            .help(isSidebarShown ? "左サイドバーを隠す (⌘\\)" : "左サイドバーを表示 (⌘\\)")
            .accessibilityLabel(isSidebarShown ? "左サイドバーを隠す" : "左サイドバーを表示")
        }

        ToolbarItem(placement: .navigation) {
            Button { vm.openFolder() } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("フォルダを開く (⌘O)")
            .accessibilityLabel("フォルダを開く")
        }

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
            .help(vm.isEXIFPanelVisible ? "EXIFパネルを隠す (⌘⌥E)" : "EXIFパネルを表示 (⌘⌥E)")
            .accessibilityLabel(vm.isEXIFPanelVisible ? "EXIFパネルを隠す" : "EXIFパネルを表示")
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
