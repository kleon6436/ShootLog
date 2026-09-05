import AppKit
import SwiftData
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
    // 連携アプリ設定の変更をSwiftDataから検知し、vmへ反映してツールバーの
    // 外部アプリメニューに即時反映させる（vm側でmodelContext.fetchを直接呼ぶとObservationが追跡できないため）
    @Query(sort: \IntegrationAppSetting.sortOrder) private var integrationSettings: [IntegrationAppSetting]

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
            .background { WindowChromeConfigurator(isToolbarVisible: vm.isToolbarVisible) }
    }

    // 写真ソース未選択時の画面。mainContent の型検査を軽く保つため切り出している
    private var emptyState: some View {
        EmptyStateView(
            onOpenFolder: vm.openFolder,
            onOpenPhotosLibrary: vm.openPhotosLibrary,
            folderHistories: vm.availableFolderHistories,
            onRestoreHistory: { history in
                Task { await vm.restoreFolder(history) }
            },
            onDeleteHistory: { history in
                vm.deleteHistory(history)
            }
        )
    }

    // body全体を1つのvarにまとめると型検査がタイムアウトするため、toolbarとの2分割にしている
    private var mainContent: some View {
        Group {
            if vm.currentPhotoSource == nil {
                emptyState
            } else {
                // 表示モードに応じてビューを切り替える。VM取得はレジストリのキャッシュ経由
                // （直接VMを生成すると状態がリセットされるため）。未登録IDはsidebarへフォールバック
                Group {
                    switch vm.currentModeID {
                    case "fullscreen":
                        FullscreenModeView(vm: ViewModeRegistry.shared.fullscreenViewModel(content: vm))
                    case "slideshow":
                        SlideshowModeView(vm: ViewModeRegistry.shared.slideshowViewModel(content: vm))
                    default:
                        SidebarModeView(vm: ViewModeRegistry.shared.sidebarViewModel(content: vm))
                    }
                }
                // モードの差し替えは即時に行い、親Viewやウィンドウクロームの
                // 暗黙アニメーションによる一瞬の旧画面表示を防ぐ。
                .transaction { transaction in
                    transaction.animation = nil
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
        .overlay(alignment: .bottom) {
            if vm.currentPhotoSource == nil, let toast = vm.toastMessage {
                ToastView(message: toast)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.toastMessage)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            Task { await vm.handleProviderDrop(provider: provider) }
            return true
        }
        .focusedSceneValue(\.openFolderAction, vm.openFolder)
        .task {
            vm.configure(context: modelContext)
        }
        .onChange(of: integrationSettings, initial: true) { _, newValue in
            vm.updateIntegrationSettings(newValue)
        }
        .sheet(isPresented: Binding(
            get: { vm.showAnalysis },
            set: { vm.showAnalysis = $0 }
        )) {
            AnalysisView(photos: vm.photos)
        }
        .sheet(isPresented: Binding(
            get: { vm.isUpscaleExportPresented },
            set: { if !$0 { vm.dismissUpscaleExport() } }
        )) {
            if let upscaleExportViewModel = vm.upscaleExportViewModel {
                UpscaleExportSheet(contentViewModel: vm, viewModel: upscaleExportViewModel)
            }
        }
        .sheet(isPresented: Binding(
            get: { vm.isDevelopExportPresented },
            set: { if !$0 { vm.dismissDevelopExport() } }
        )) {
            if let developExportViewModel = vm.developExportViewModel {
                DevelopExportSheet(contentViewModel: vm, viewModel: developExportViewModel)
            }
        }
        .alert("common.error", isPresented: Binding(
            get: { vm.error != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("common.ok") { vm.error = nil }
        } message: {
            let message: String = vm.error?.localizedDescription ?? ""
            Text(message)
        }
        .alert("photosLibrary.permissionDenied.alert.title", isPresented: Binding(
            get: { vm.isPhotosLibraryPermissionAlertPresented },
            set: { vm.isPhotosLibraryPermissionAlertPresented = $0 }
        )) {
            Button("common.ok") { vm.isPhotosLibraryPermissionAlertPresented = false }
        } message: {
            Text("photosLibrary.permissionDenied.alert.message")
        }
    }

}

#Preview {
    ContentView()
}
