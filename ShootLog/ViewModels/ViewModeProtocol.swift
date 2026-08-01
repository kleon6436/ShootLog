import SwiftUI

// 全表示モードが準拠するプロトコル。新モードは準拠型を1つ作り ViewModeRegistry に登録するだけ
// View生成(makeView)は持たない: ViewModelがView型を知る設計を避けるため、
// モード切替はView側(ContentView)がcurrentModeIDを見てswitchする
protocol ViewModeProtocol: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }           // SF Symbols 名
    var keyboardShortcut: KeyEquivalent? { get }
}

// 各モード専用ViewModel（Fullscreen/Slideshow/Sidebar）がContentViewModelへ委譲するプロパティ・
// メソッドの重複実装をなくすための共通プロトコル。準拠側はcontentを提供するだけでよい
@MainActor
protocol ContentViewModelProxy: AnyObject {
    var content: ContentViewModel { get }
}

// 委譲のデフォルト実装。ContentViewModelを単一の真実源とする。
// なおここでの委譲は @Observable の追跡を壊さない：@Observableマクロが計装するのは
// 格納プロパティのみで、転送用の計算プロパティはクラス本体に書いても計装対象外。
// 実際の追跡は content 側の格納プロパティ読み取りで登録されるため、
// 定義場所をプロトコル拡張へ移しても観測の挙動は従来と同一である
extension ContentViewModelProxy {
    var selectedPhoto: Photo? { content.selectedPhoto }
    var currentEditInfo: EditInfo? { content.currentEditInfo }
    var selectedIndex: Int { content.selectedIndex }
    var photos: [Photo] { content.photos }

    // ツールバー（Pickerの選択）から直接切り替えるためget/set両方必要
    var currentModeID: String {
        get { content.currentModeID }
        set { content.currentModeID = newValue }
    }

    // ツールバーのトグルとも同期する必要があるため委譲する
    var showFavoritesOnly: Bool {
        get { content.showFavoritesOnly }
        set { content.showFavoritesOnly = newValue }
    }

    func selectNext() { content.selectNext() }
    func selectPrevious() { content.selectPrevious() }
    func switchToSidebar() { content.switchToSidebar() }
    // 選択中写真を右へ90°回転する（Fullscreen/Slideshowなど独自状態を持たないモード向けの共通委譲）
    func rotateSelectedPhoto() { content.rotateSelectedPhoto() }
    func openFolder() { content.openFolder() }
    func openAnalysis() { content.openAnalysis() }
    func openInExternalApp(_ adapter: any ExternalAppProtocol) { content.openInExternalApp(adapter) }

    // ModeToolbarComponents（ModeTogglePicker/ExternalAppMenu）へ渡す一覧。
    // シングルトンアクセスはContentViewModel側に集約し、Viewは委譲経由で受け取るだけにする
    var availableModes: [any ViewModeProtocol] { content.availableModes }
    var externalApps: [any ExternalAppProtocol] { content.externalApps }
}
