import SwiftUI

// 全表示モード（sidebar/fullscreen/slideshow）の標準ツールバーで共有する部品群。
// ForEachをツールバー式に直接書くと型検査がタイムアウトするため独立Viewへ切り出している

// ツールバー内の表示モード切替（セグメント）。モード一覧は呼び出し元のVM経由で渡す
// （ViewModeRegistry.sharedへのアクセスはVM層に閉じ、View層からは直接参照しない）
struct ModeTogglePicker: View {
    @Binding var currentModeID: String
    let modes: [any ViewModeProtocol]

    var body: some View {
        Picker("表示モード", selection: $currentModeID) {
            ForEach(modes, id: \.id) { mode in
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

// 外部アプリで開くメニュー。アプリ一覧は呼び出し元のVM経由で渡す
// （ExternalAppRegistry.sharedへのアクセスはVM層に閉じ、View層からは直接参照しない）
struct ExternalAppMenu: View {
    let apps: [any ExternalAppProtocol]
    let onSelect: (any ExternalAppProtocol) -> Void

    var body: some View {
        Menu {
            ForEach(apps, id: \.id) { adapter in
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
