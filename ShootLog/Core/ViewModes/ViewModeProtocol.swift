import SwiftUI

// 全表示モードが準拠するプロトコル。新モードは準拠型を1つ作り ViewModeRegistry に登録するだけ
protocol ViewModeProtocol: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }           // SF Symbols 名
    var keyboardShortcut: KeyEquivalent? { get }
    func makeView(vm: ContentViewModel) -> AnyView
}
