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
    private enum HeaderLayout {
        static let trafficLightInset: CGFloat = 78
        static let verticalPadding: CGFloat = 7
        static let minHeight: CGFloat = 44
        static let totalHeight: CGFloat = minHeight + (verticalPadding * 2)
    }

    @State private var vm = ContentViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false

    private var sidebarToggleAction: (() -> Void)? {
        guard vm.currentModeID == "sidebar", vm.currentFolderURL != nil else { return nil }
        return { vm.requestSidebarToggle() }
    }

    private var inspectorToggleAction: (() -> Void)? {
        guard vm.currentModeID == "sidebar", vm.currentFolderURL != nil else { return nil }
        return { vm.requestInspectorToggle() }
    }

    private var sidebarVisibilityState: Bool? {
        vm.currentModeID == "sidebar" && vm.currentFolderURL != nil ? vm.isSidebarVisible : nil
    }

    private var inspectorVisibilityState: Bool? {
        vm.currentModeID == "sidebar" && vm.currentFolderURL != nil ? vm.isInspectorVisible : nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            mainContent
                .padding(.top, HeaderLayout.totalHeight)

            windowHeaderBar
                .ignoresSafeArea(.container, edges: .top)
        }
            .ignoresSafeArea(.container, edges: .top)
            .toolbar(removing: .sidebarToggle)
            .focusedValue(\.toggleSidebarAction, sidebarToggleAction)
            .focusedValue(\.toggleInspectorAction, inspectorToggleAction)
            .focusedValue(\.sidebarVisibilityState, sidebarVisibilityState)
            .focusedValue(\.inspectorVisibilityState, inspectorVisibilityState)
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
                // 表示モードに応じてビューを切り替える（レジストリから動的解決）。
                // 未登録IDでnilになった場合もsidebarモードのmakeView経由でフォールバックし、
                // ViewModelBoxのキャッシュ経路を必ず通す（直接VMを生成すると状態がリセットされる）
                let view = ViewModeRegistry.shared.mode(for: vm.currentModeID)?.makeView(vm: vm)
                view ?? ViewModeRegistry.shared.mode(for: "sidebar")?.makeView(vm: vm) ?? AnyView(EmptyView())
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
        .focusedValue(\.openFolderAction, vm.openFolder)
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

    // AppKitのネイティブtoolbarではなく、アプリ管理のヘッダーバーを描画する。
    // これによりシステム挿入のサイドバートグルへ依存せず、表示内容を完全に制御できる。
    private var windowHeaderBar: some View {
        HStack(spacing: Spacing.medium) {
            Color.clear
                .frame(width: HeaderLayout.trafficLightInset, height: 1)

            HStack(spacing: Spacing.small) {
                if vm.currentModeID == "sidebar", vm.currentFolderURL != nil {
                    Button(action: vm.requestSidebarToggle) {
                        Image(systemName: "sidebar.left")
                    }
                    .help(vm.isSidebarVisible ? "左サイドバーを隠す (⌘\\)" : "左サイドバーを表示 (⌘\\)")
                    .accessibilityLabel(vm.isSidebarVisible ? "左サイドバーを隠す" : "左サイドバーを表示")
                    .buttonStyle(WindowHeaderIconButtonStyle())
                }

                // 表示モードボタン（レジストリから動的生成）。
                // セグメントコントロール的な一体感を出すため、3ボタンを1つの
                // HStackにまとめ、外側に共有のグループ背景を与える。個々の
                // ボタンには恒常的な枠を付けず、選択中のボタンのみ内側で
                // アクセント塗り＋前景色反転する（ToolbarButtonStyle側で処理）。
                HStack(spacing: 0) {
                    ModeToggleRow(
                        currentModeID: vm.currentModeID,
                        onSelect: { vm.currentModeID = $0 }
                    )
                }
                .padding(2)
                .background(Color.onDarkCanvas.opacity(0.12), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
                .disabled(vm.currentFolderURL == nil)

                Button { vm.showFavoritesOnly.toggle() } label: {
                    Image(systemName: vm.showFavoritesOnly ? "star.fill" : "star")
                }
                .help("お気に入りのみ表示")
                .accessibilityLabel("お気に入りのみ表示")
                .disabled(vm.photos.isEmpty)
                .buttonStyle(WindowHeaderIconButtonStyle())
            }

            Spacer(minLength: Spacing.xLarge)

            HStack(spacing: Spacing.small) {
                if vm.currentModeID == "sidebar", vm.currentFolderURL != nil {
                    Button(action: vm.requestInspectorToggle) {
                        Image(systemName: vm.isInspectorVisible ? "sidebar.right" : "chevron.backward.to.line")
                    }
                    .help(vm.isInspectorVisible ? "EXIFパネルを隠す (⌘⌥E)" : "EXIFパネルを表示 (⌘⌥E)")
                    .accessibilityLabel(vm.isInspectorVisible ? "EXIFパネルを隠す" : "EXIFパネルを表示")
                    .buttonStyle(WindowHeaderIconButtonStyle())
                }

                Button { vm.openFolder() } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("フォルダを開く (⌘O)")
                .accessibilityLabel("フォルダを開く")
                .buttonStyle(WindowHeaderIconButtonStyle())

                Button { vm.openAnalysis() } label: {
                    Image(systemName: "chart.bar")
                }
                .help("撮影傾向を分析 (⌘I)")
                .accessibilityLabel("分析")
                .keyboardShortcut("i", modifiers: .command)
                .disabled(vm.photos.isEmpty)
                .buttonStyle(WindowHeaderIconButtonStyle())

                Menu {
                    ForEach(ExternalAppRegistry.shared.availableAdapters, id: \.id) { adapter in
                        Button { vm.openInExternalApp(adapter) } label: {
                            Label(adapter.displayName, systemImage: adapter.symbolName)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .toolbarButtonAppearance()
                }
                .help("外部アプリで開く")
                .accessibilityLabel("外部アプリで開く")
                .disabled(vm.selectedPhoto == nil)
                .menuStyle(.borderlessButton)

                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .help("設定を開く")
                .accessibilityLabel("設定を開く")
                .buttonStyle(WindowHeaderIconButtonStyle())
            }
        }
        .padding(.leading, Spacing.medium)
        .padding(.trailing, Spacing.xLarge)
        .padding(.vertical, HeaderLayout.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: HeaderLayout.minHeight, alignment: .leading)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.controlBorder)
                .frame(height: 0.5)
        }
    }

}

private struct WindowHeaderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .toolbarButtonAppearance()
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

// 表示モードボタン群。ForEachをContentView.body内に直接書くと式全体の型検査が
// タイムアウトするため独立Viewへ切り出す
private struct ModeToggleRow: View {
    let currentModeID: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ViewModeRegistry.shared.enabledModes, id: \.id) { mode in
                ModeToggleButton(
                    mode: mode,
                    isSelected: currentModeID == mode.id,
                    action: { onSelect(mode.id) }
                )
            }
        }
    }
}

// 表示モード切替ボタン。ForEach内に直接書くと式全体の型検査がタイムアウトするため独立Viewへ切り出す
private struct ModeToggleButton: View {
    let mode: any ViewModeProtocol
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode.symbolName)
        }
        .help(mode.displayName)
        .accessibilityLabel(mode.displayName)
        .buttonStyle(ToolbarButtonStyle(isSelected: isSelected))
    }
}

#Preview {
    ContentView()
}
