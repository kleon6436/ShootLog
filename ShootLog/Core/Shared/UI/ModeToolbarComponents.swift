import SwiftUI

// 全表示モード（sidebar/fullscreen/slideshow）の標準ツールバーで共有する部品群。
// ForEachをツールバー式に直接書くと型検査がタイムアウトするため独立Viewへ切り出している

// ツールバー内の表示モード切替（セグメント）
struct ModeTogglePicker: View {
    @Binding var currentModeID: String

    var body: some View {
        Picker("表示モード", selection: $currentModeID) {
            ForEach(ViewModeRegistry.shared.enabledModes, id: \.id) { mode in
                Image(systemName: mode.symbolName)
                    .accessibilityLabel(mode.displayName)
                    .tag(mode.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("表示モード")
    }
}

// 外部アプリで開くメニュー
struct ExternalAppMenu: View {
    let onSelect: (any ExternalAppProtocol) -> Void

    var body: some View {
        Menu {
            ForEach(ExternalAppRegistry.shared.availableAdapters, id: \.id) { adapter in
                Button { onSelect(adapter) } label: {
                    Label(adapter.displayName, systemImage: adapter.symbolName)
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .help("外部アプリで開く")
        .accessibilityLabel("外部アプリで開く")
    }
}
