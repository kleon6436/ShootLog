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
    @State private var vm = MainViewModel()
    @Environment(\.modelContext) private var modelContext
    @State private var isDropTargeted = false

    var body: some View {
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
                // 表示モードに応じてビューを切り替える（レジストリから動的解決）
                let view = ViewModeRegistry.shared.mode(for: vm.currentModeID)?.makeView(vm: vm)
                view ?? AnyView(SidebarModeView(vm: vm))
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
            Text(vm.error?.localizedDescription ?? "")
        }
        .toolbar {
            // 表示モードボタン（レジストリから動的生成）。
            // セグメントコントロール的な一体感を出すため、3ボタンを1つの
            // HStackにまとめ、外側に共有のグループ背景を与える。個々の
            // ボタンには恒常的な枠を付けず、選択中のボタンのみ内側で
            // アクセント塗り＋前景色反転する（ToolbarButtonStyle側で処理）。
            ToolbarItemGroup(placement: .navigation) {
                HStack(spacing: 2) {
                    ForEach(ViewModeRegistry.shared.enabledModes, id: \.id) { mode in
                        Button { vm.currentModeID = mode.id } label: {
                            Image(systemName: mode.symbolName)
                        }
                        .help(mode.displayName)
                        .accessibilityLabel(mode.displayName)
                        .buttonStyle(ToolbarButtonStyle(isSelected: vm.currentModeID == mode.id))
                    }
                }
                .padding(2)
                .background(Color.onDarkCanvas.opacity(0.12), in: RoundedRectangle(cornerRadius: CornerRadius.medium))
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
            }
        }
        // ツールバーが常に黒背景になるよう固定する、システムのマテリアル/アクセントカラーに依存させない
        .toolbarBackground(Color.black, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        // ここがウィンドウツールバーが実際に組み立てられるスコープ。SidebarModeView側にも
        // 同種の指定があるが、そちらは子スコープであり、ContentView独自のnavigation配置
        // ツールバー内容（表示モード切替3ボタン）を供給しているこの親スコープには及ばない。
        // 未指定だとmacOSがNavigationSplitViewを検知し標準サイドバートグルを自動再挿入するため、
        // 実効箇所として明示的にここでも除去する（SidebarModeView側はフェイルセーフとして残す）。
        .toolbar(removing: .sidebarToggle)
    }
}

#Preview {
    ContentView()
}
