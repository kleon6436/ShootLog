import SwiftUI

// 表示モードを管理するレジストリ。ツールバー・設定画面はここを参照するだけでよい。
// 各モードのViewModelはここでキャッシュ管理する（モード切替のたびVMを再生成すると状態がリセットされるため）。
// View生成自体はここでは行わない: どのViewを表示するかはView側(ContentView)がcurrentModeIDで判断する
@Observable
@MainActor
final class ViewModeRegistry {
    static let shared = ViewModeRegistry()

    private(set) var enabledModes: [any ViewModeProtocol] = []

    private let sidebarBox = ViewModelBox<SidebarViewModel>()
    private let fullscreenBox = ViewModelBox<FullscreenViewModel>()
    private let slideshowBox = ViewModelBox<SlideshowViewModel>()

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

    func sidebarViewModel(content: ContentViewModel) -> SidebarViewModel {
        sidebarBox.get { SidebarViewModel(content: content) }
    }

    func fullscreenViewModel(content: ContentViewModel) -> FullscreenViewModel {
        fullscreenBox.get { FullscreenViewModel(content: content) }
    }

    func slideshowViewModel(content: ContentViewModel) -> SlideshowViewModel {
        slideshowBox.get { SlideshowViewModel(content: content) }
    }
}

// MARK: - SidebarMode

struct SidebarMode: ViewModeProtocol {
    let id = "sidebar"
    let displayName = "サイドバー"
    let symbolName = "rectangle.split.3x1"
    let keyboardShortcut: KeyEquivalent? = nil
}

// MARK: - FullscreenMode

struct FullscreenMode: ViewModeProtocol {
    let id = "fullscreen"
    let displayName = "フルスクリーン"
    let symbolName = "arrow.up.left.and.arrow.down.right"
    let keyboardShortcut: KeyEquivalent? = "f"
}

// MARK: - SlideshowMode

struct SlideshowMode: ViewModeProtocol {
    let id = "slideshow"
    let displayName = "スライドショー"
    let symbolName = "play.rectangle"
    let keyboardShortcut: KeyEquivalent? = "p"
}
