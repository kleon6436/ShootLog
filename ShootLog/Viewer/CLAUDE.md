# Viewer/ — 表示モードの拡張設計

新モードを追加するときは `ViewModeProtocol` に準拠した型を作り、`ViewModeRegistry` に1行追加するだけ。ツールバー・設定画面は変更不要。

```swift
// 全表示モードが準拠するプロトコル
protocol ViewModeProtocol: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }          // SF Symbols名
    var keyboardShortcut: KeyEquivalent? { get }
    @ViewBuilder
    func makeView(photos: [Photo], selection: Binding<Photo?>) -> AnyView
}

// 初期登録モード
// SidebarMode     (id: "sidebar")   ← デフォルト
// FullscreenMode  (id: "fullscreen")
// SlideshowMode   (id: "slideshow")
```
