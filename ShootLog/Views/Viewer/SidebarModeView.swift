import SwiftUI

// サイドバーモード。左=写真一覧 / 中央=ビューア / 右=EXIFパネル の3カラム構成
struct SidebarModeView: View {
    @Bindable var vm: MainViewModel
    // サイドバー幅（Capture One風に可変・次回起動時の初期幅として近似復元する）
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 140
    @State private var widthSaveTask: Task<Void, Never>?
    @FocusState private var isSidebarFocused: Bool
    // サイドバー（左カラム）の表示状態。ユーザーが開閉トグルボタン・ドラッグ収縮で可変に制御する
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 左: 写真一覧（最小 120pt、理想 sidebarWidth pt、最大 400pt）
            PhotoListView(photos: vm.photos, selection: $vm.selectedPhoto)
                .navigationSplitViewColumnWidth(min: 120, ideal: sidebarWidth, max: 400)
                // 右カラム（EXIFPanelView）とのフラット材質を対にするための明示背景
                .background(.regularMaterial)
                .background {
                    // NavigationSplitView はドラッグ後の実幅を読み取る公開APIを持たないため、
                    // GeometryReaderで描画幅を観測しデバウンスして近似的に永続化する
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.size.width) { _, newWidth in
                                scheduleWidthSave(newWidth)
                            }
                    }
                }
                .background {
                    // SwiftUIの.toolbar(removing: .sidebarToggle)だけではmacOS 26で
                    // AppKitが自動挿入するネイティブのサイドバートグルが残り、自前の
                    // 開閉トグルボタンと重複するため、AppKit階層から物理的に取り除く
                    NativeSidebarToggleRemover()
                }
                .overlay(alignment: .trailing) {
                    // 中央カラム（ビューア）との境界線。右カラムのEXIFPanelViewと対になる表現
                    Rectangle()
                        .fill(Color.controlBorder)
                        .frame(width: 0.5)
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
        } content: {
            // 中央: ビューア（黒背景）+ 編集ツールバー
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
                        onRotate: { vm.rotateSelectedPhoto() },
                        onToggleCrop: { vm.toggleCropMode() },
                        onReset: { vm.resetEdits() }
                    )
                }
            }
        } detail: {
            // 右: EXIF パネル（156pt 固定）
            EXIFPanelView(photo: vm.selectedPhoto)
                .navigationSplitViewColumnWidth(156)
        }
        .toolbar {
            // 自前のサイドバー開閉トグル。ネイティブトグルは除去しモード切替ボタンとも
            // アイコンを分けているため、これが唯一の開閉手段になる
            ToolbarItem(placement: .navigation) {
                Button {
                    // .doubleColumn は左カラムのみを隠す（.detailOnly は中央カラムも隠すため不可）
                    withAnimation(.easeInOut(duration: 0.2)) {
                        columnVisibility = columnVisibility == .all ? .doubleColumn : .all
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("サイドバーを開閉 (⌘\\)")
                .accessibilityLabel("サイドバーを開閉")
                .keyboardShortcut("\\", modifiers: .command)
            }
        }
        .toolbar(removing: .sidebarToggle) // macOS標準（AppKit自動挿入）のサイドバー切り替えボタンを除去し、自前トグルとの重複を防ぐ
        .overlay(alignment: .bottom) {
            // トースト（お気に入り登録など）
            if let toast = vm.toastMessage {
                ToastView(message: toast)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.toastMessage)
        .onChange(of: vm.selectedPhoto) { _, photo in
            guard let photo else { return }
            vm.loadEditInfo(for: photo)
            Task { await vm.loadEXIFIfNeeded(for: photo) }
        }
    }

    // MARK: - Private

    // ドラッグ中の高頻度書き込みを避けるため、1pt未満の変化は無視し300msデバウンスしてから保存する
    private func scheduleWidthSave(_ newWidth: Double) {
        guard abs(newWidth - sidebarWidth) >= 1 else { return }
        widthSaveTask?.cancel()
        widthSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            sidebarWidth = newWidth
        }
    }
}
