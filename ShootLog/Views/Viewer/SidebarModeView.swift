import AppKit
import SwiftUI

private enum SidebarColumnVisibilityState: String {
    case automatic
    case all
    case doubleColumn
    case detailOnly

    init(_ visibility: NavigationSplitViewVisibility) {
        switch visibility {
        case .automatic:
            self = .automatic
        case .all:
            self = .all
        case .doubleColumn:
            self = .doubleColumn
        case .detailOnly:
            self = .detailOnly
        default:
            self = .all
        }
    }

    var navigationVisibility: NavigationSplitViewVisibility {
        switch self {
        case .automatic:
            .automatic
        case .all:
            .all
        case .doubleColumn:
            .doubleColumn
        case .detailOnly:
            .detailOnly
        }
    }
}

// サイドバーモード。左=写真一覧 / 中央=ビューア / 右=EXIFパネル の3カラム構成
struct SidebarModeView: View {
    @Bindable var vm: SidebarViewModel
    // サイドバー幅（Capture One風に可変・次回起動時の初期幅として近似復元する）
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 140
    @AppStorage("sidebarColumnVisibility") private var storedColumnVisibility: String = SidebarColumnVisibilityState.all.rawValue
    @FocusState private var isSidebarFocused: Bool
    // サイドバー（左カラム）の表示状態。ユーザーが開閉トグルボタン・ドラッグ収縮で可変に制御する
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 左: 写真一覧（最小 120pt、理想 sidebarWidth pt、最大 400pt）
            PhotoListView(photos: vm.displayedPhotos, selection: $vm.selectedPhoto)
                .navigationSplitViewColumnWidth(min: 120, ideal: sidebarWidth, max: 400)
                // 右カラム（EXIFPanelView）とのフラット材質を対にするための明示背景
                .background(.regularMaterial)
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
            // 右: EXIF パネル（156pt 固定）。非表示トグル時はカラム自体を描画しない
            if vm.isEXIFPanelVisible {
                EXIFPanelView(photo: vm.selectedPhoto)
                    .navigationSplitViewColumnWidth(156)
            }
        }
        .searchable(text: $vm.searchText)
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
            storedColumnVisibility = SidebarColumnVisibilityState(newValue).rawValue
            vm.setSidebarVisible(newValue == .all)
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

    private func restoreColumnVisibility() {
        guard let state = SidebarColumnVisibilityState(rawValue: storedColumnVisibility) else {
            columnVisibility = .all
            vm.setSidebarVisible(true)
            return
        }
        columnVisibility = state.navigationVisibility
        vm.setSidebarVisible(state.navigationVisibility == .all)
        vm.setInspectorVisible(vm.isEXIFPanelVisible)
    }

    private func toggleSidebar() {
        let selector = #selector(NSSplitViewController.toggleSidebar(_:))
        let window = NSApp.keyWindow ?? NSApp.mainWindow

        if window?.firstResponder?.tryToPerform(selector, with: nil) == true {
            return
        }

        if window?.contentViewController?.tryToPerform(selector, with: nil) == true {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = columnVisibility == .all ? .doubleColumn : .all
        }
        vm.setSidebarVisible(columnVisibility == .all)
    }

    private func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.2)) {
            vm.isEXIFPanelVisible.toggle()
        }
        vm.setInspectorVisible(vm.isEXIFPanelVisible)
    }
}
