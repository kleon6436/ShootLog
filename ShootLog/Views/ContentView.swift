import AppKit
import SwiftUI
import UniformTypeIdentifiers

// FocusedValue キー: ファイルメニューコマンドから openFolder を呼ぶために使う
private struct OpenFolderActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

// FocusedValue キー: サイドバー開閉コマンドから sidebar モードの左カラム開閉を呼ぶために使う
private struct ToggleSidebarActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

// FocusedValue キー: Viewメニューやツールバーから右EXIFパネル開閉を呼ぶために使う
private struct ToggleInspectorActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

// FocusedValue キー: Viewメニューで表示/非表示の文言を出し分けるための状態
private struct SidebarVisibilityStateKey: FocusedValueKey {
    typealias Value = Bool
}

// FocusedValue キー: Viewメニューでインスペクタ表示状態の文言を出し分けるための状態
private struct InspectorVisibilityStateKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var openFolderAction: (() -> Void)? {
        get { self[OpenFolderActionKey.self] }
        set { self[OpenFolderActionKey.self] = newValue }
    }

    var toggleSidebarAction: (() -> Void)? {
        get { self[ToggleSidebarActionKey.self] }
        set { self[ToggleSidebarActionKey.self] = newValue }
    }

    var toggleInspectorAction: (() -> Void)? {
        get { self[ToggleInspectorActionKey.self] }
        set { self[ToggleInspectorActionKey.self] = newValue }
    }

    var sidebarVisibilityState: Bool? {
        get { self[SidebarVisibilityStateKey.self] }
        set { self[SidebarVisibilityStateKey.self] = newValue }
    }

    var inspectorVisibilityState: Bool? {
        get { self[InspectorVisibilityStateKey.self] }
        set { self[InspectorVisibilityStateKey.self] = newValue }
    }
}

// アプリのルートビュー。フォルダ選択状態と表示モードに応じてビューを切り替える
struct ContentView: View {
    @State private var vm = ContentViewModel()
    @Environment(\.modelContext) private var modelContext
    @State private var isDropTargeted = false

    private var sidebarToggleAction: (() -> Void)? {
        guard vm.isSidebarModeActive else { return nil }
        return { vm.requestSidebarToggle() }
    }

    private var inspectorToggleAction: (() -> Void)? {
        guard vm.isSidebarModeActive else { return nil }
        return { vm.requestInspectorToggle() }
    }

    private var sidebarVisibilityState: Bool? {
        vm.isSidebarModeActive ? vm.isSidebarVisible : nil
    }

    private var inspectorVisibilityState: Bool? {
        vm.isSidebarModeActive ? vm.isInspectorVisible : nil
    }

    var body: some View {
        // 全モード共通で標準 NSToolbar を使う。ツールバーの中身は各モードビュー
        // （SidebarModeView / FullscreenModeView / SlideshowModeView）が .toolbar で提供する
        mainContent
            // ツールバーの表示/非表示は WindowChromeConfigurator が AppKit 側で行う。
            // .toolbar(.hidden, for: .windowToolbar) はタイトルバーごと消して
            // 信号機まで隠してしまうため使わない
            .focusedSceneValue(\.toggleSidebarAction, sidebarToggleAction)
            .focusedSceneValue(\.toggleInspectorAction, inspectorToggleAction)
            .focusedSceneValue(\.sidebarVisibilityState, sidebarVisibilityState)
            .focusedSceneValue(\.inspectorVisibilityState, inspectorVisibilityState)
            .background { WindowChromeConfigurator() }
    }

    // body全体を1つのvarにまとめると型検査がタイムアウトするため、toolbarとの2分割にしている
    private var mainContent: some View {
        Group {
            if vm.currentFolderURL == nil {
                EmptyStateView(
                    onOpenFolder: vm.openFolder,
                    folderHistories: vm.folderHistories,
                    onRestoreHistory: { history in
                        Task { await vm.restoreFolder(history) }
                    }
                )
            } else {
                // 表示モードに応じてビューを切り替える。VM取得はレジストリのキャッシュ経由
                // （直接VMを生成すると状態がリセットされるため）。未登録IDはsidebarへフォールバック
                switch vm.currentModeID {
                case "fullscreen":
                    FullscreenModeView(vm: ViewModeRegistry.shared.fullscreenViewModel(content: vm))
                case "slideshow":
                    SlideshowModeView(vm: ViewModeRegistry.shared.slideshowViewModel(content: vm))
                default:
                    SidebarModeView(vm: ViewModeRegistry.shared.sidebarViewModel(content: vm))
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            Task { await vm.handleProviderDrop(provider: provider) }
            return true
        }
        .focusedSceneValue(\.openFolderAction, vm.openFolder)
        .task {
            vm.configure(context: modelContext)
        }
        .sheet(isPresented: Binding(
            get: { vm.showAnalysis },
            set: { vm.showAnalysis = $0 }
        )) {
            AnalysisView(photos: vm.photos)
        }
        .alert("エラー", isPresented: Binding(
            get: { vm.error != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("OK") { vm.error = nil }
        } message: {
            let message: String = vm.error?.localizedDescription ?? ""
            Text(message)
        }
    }

}

#Preview {
    ContentView()
}
