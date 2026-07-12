import SwiftUI

// 表示モードを管理するレジストリ。ツールバー・設定画面はここを参照するだけでよい
@Observable
@MainActor
final class ViewModeRegistry {
    static let shared = ViewModeRegistry()

    private(set) var enabledModes: [any ViewModeProtocol] = []

    private init() {
        // 新モードは1行追加するだけ。ツールバー・設定画面は変更不要
        enabledModes = [
            SidebarMode(),
            FullscreenMode(),
            SlideshowMode(),
        ]
    }

    func mode(for id: String) -> (any ViewModeProtocol)? {
        enabledModes.first { $0.id == id }
    }
}

// MARK: - SidebarMode

struct SidebarMode: @MainActor ViewModeProtocol {
    let id = "sidebar"
    let displayName = "サイドバー"
    let symbolName = "rectangle.split.3x1"
    let keyboardShortcut: KeyEquivalent? = nil

    @MainActor func makeView(vm: MainViewModel) -> AnyView {
        AnyView(SidebarModeView(vm: vm))
    }
}
