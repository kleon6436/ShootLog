import SwiftUI
import UniformTypeIdentifiers

// FocusedValue キー: ファイルメニューコマンドから openFolder を呼ぶために使う
private struct OpenFolderActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var openFolderAction: (() -> Void)? {
        get { self[OpenFolderActionKey.self] }
        set { self[OpenFolderActionKey.self] = newValue }
    }
}

// アプリのルートビュー。フォルダ選択状態と表示モードに応じてビューを切り替える
struct ContentView: View {
    @State private var vm = ContentViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false

    var body: some View {
        mainContent
            .toolbar { toolbarContent }
            // ツールバーが常に黒背景になるよう固定する、システムのマテリアル/アクセントカラーに依存させない
            .toolbarBackground(Color.black, for: .windowToolbar)
            .toolbarColorScheme(.dark, for: .windowToolbar)
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

    // 表示モードボタン（レジストリから動的生成）。
    // セグメントコントロール的な一体感を出すため、3ボタンを1つの
    // HStackにまとめ、外側に共有のグループ背景を与える。個々の
    // ボタンには恒常的な枠を付けず、選択中のボタンのみ内側で
    // アクセント塗り＋前景色反転する（ToolbarButtonStyle側で処理）。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ModeToggleRow(
                currentModeID: vm.currentModeID,
                onSelect: { vm.currentModeID = $0 }
            )
            .padding(2)
            .background(Color.onDarkCanvas.opacity(0.12), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
        }
        // 表示フィルタクラスタ: お気に入りのみ表示のトグル。モード切替の直後に配置し
        // 「表示に関する操作」として一塊にする
        ToolbarItemGroup(placement: .navigation) {
            Button { vm.showFavoritesOnly.toggle() } label: {
                Image(systemName: vm.showFavoritesOnly ? "star.fill" : "star")
            }
            .help("お気に入りのみ表示")
            .accessibilityLabel("お気に入りのみ表示")
        }
        // フォルダ・分析・共有は独立した単発アクションのため、装飾なしの
        // 素のButton/Menuに戻し、システム標準のホバー/押下ハイライトに
        // 委ねる（グループ選択専用のToolbarButtonStyle/toolbarButtonAppearanceは適用しない）。
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

            // 外部アプリで開くメニュー（写真選択時に有効）
            Menu {
                ForEach(ExternalAppRegistry.shared.availableAdapters, id: \.id) { adapter in
                    Button { vm.openInExternalApp(adapter) } label: {
                        Label(adapter.displayName, systemImage: adapter.symbolName)
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("外部アプリで開く")
            .accessibilityLabel("外部アプリで開く")
            .disabled(vm.selectedPhoto == nil)
            .menuStyle(.borderlessButton)

            // 設定は他のアクション群と視覚的に分離するため末尾に配置
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .help("設定を開く")
            .accessibilityLabel("設定を開く")
        }
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
