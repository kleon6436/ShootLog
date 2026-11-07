import SwiftUI

// ビューア下端のパスバー（Finder のパスバー風）。選択写真（写真が無ければ表示フォルダ）のフルパスを出す。
// rootURL（移動範囲の上限）以下のフォルダ要素はクリックでそのフォルダへ移動し、それより上の要素は非活性にする
struct FolderPathBar: View {
    let targetURL: URL
    let rootURL: URL
    let isFile: Bool
    let onNavigate: (URL) -> Void
    let onCopyPath: () -> Void
    let onRevealInFinder: () -> Void

    // バーの高さ。トーストの退避量（SidebarModeView.toastBottomInset）にも使う
    static let height: CGFloat = 24
    // 省略せずに並べる要素数の上限。超えたら先頭と末尾2要素を残して間を「…」に畳む
    private static let maxVisibleComponents = 4

    // フォルダ部分の要素のキャッシュ（フォルダ・ルート単位）。表示名の取得はネットワークボリュームで重いため、
    // 同じフォルダ内で写真を切り替えたときは再計算せず、末尾のファイル要素だけを差し替える
    @State private var folderComponentsCache: [FolderKey: [FolderPathComponent]] = [:]

    var body: some View {
        HStack(spacing: Spacing.xSmall) {
            ForEach(Array(displayItems.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                switch item {
                case .component(let component):
                    componentView(component)
                case .collapsed(let hidden):
                    collapsedMenu(hidden)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.medium)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PathBarBackground())
        .help(Text(verbatim: targetURL.path))
        .contextMenu {
            Button("contextMenu.pathBar.copyPath", action: onCopyPath)
            Button("contextMenu.pathBar.revealInFinder", action: onRevealInFinder)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("a11y.viewer.pathBar")
        // 表示名の取得（FileManager.displayName）はファイルシステムを参照するため MainActor の外で行う
        .task(id: folderKey) {
            let key = folderKey
            guard folderComponentsCache[key] == nil else { return }
            let made = await Task.detached(priority: .userInitiated) {
                FolderPathComponents.make(targetURL: key.folderURL, rootURL: key.rootURL, isFile: false)
            }.value
            guard !Task.isCancelled else { return }
            folderComponentsCache[key] = made
        }
    }

    private struct FolderKey: Hashable {
        let folderURL: URL
        let rootURL: URL
    }

    // 表示中のパスのフォルダ部分。ファイルならその親フォルダ
    private var folderKey: FolderKey {
        FolderKey(
            folderURL: isFile ? targetURL.deletingLastPathComponent() : targetURL,
            rootURL: rootURL
        )
    }

    // 現在のパスに対応する要素。フォルダ部分を計算し終えるまでは何も出さず、
    // 前のパスの要素（移動先が古いボタン）を見せたり押させたりしない
    private var components: [FolderPathComponent] {
        guard let folderComponents = folderComponentsCache[folderKey] else { return [] }
        guard isFile else { return folderComponents }
        // ファイル名は拡張子まで見せたいので displayName ではなく実ファイル名を使う
        let file = FolderPathComponent(name: targetURL.lastPathComponent, url: targetURL, kind: .file)
        return folderComponents + [file]
    }

    private enum DisplayItem {
        case component(FolderPathComponent)
        case collapsed([FolderPathComponent])
    }

    // 長いパスは先頭（ボリューム）と末尾2要素を残し、間を「…」のメニューに畳む
    private var displayItems: [DisplayItem] {
        guard components.count > Self.maxVisibleComponents else {
            return components.map(DisplayItem.component)
        }
        let head = components[0]
        let hidden = Array(components[1..<(components.count - 2)])
        let tail = components.suffix(2).map(DisplayItem.component)
        return [.component(head), .collapsed(hidden)] + tail
    }

    @ViewBuilder
    private func componentView(_ component: FolderPathComponent) -> some View {
        switch component.kind {
        case .folderInRoot:
            Button {
                onNavigate(component.url)
            } label: {
                Label {
                    Text(verbatim: component.name)
                } icon: {
                    Image(systemName: "folder")
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(navigateHelp(component.name))
            .accessibilityLabel(navigateHelp(component.name))
        case .outsideRoot:
            Text(verbatim: component.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
        case .file:
            Label {
                Text(verbatim: component.name)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "photo")
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    private func collapsedMenu(_ hidden: [FolderPathComponent]) -> some View {
        Menu {
            ForEach(hidden) { component in
                Button {
                    onNavigate(component.url)
                } label: {
                    Text(verbatim: component.name)
                }
                .disabled(component.kind != .folderInRoot)
            }
        } label: {
            Text(verbatim: "…")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(verbatim: hidden.map(\.name).joined(separator: " › ")))
        .accessibilityLabel("viewer.pathBar.collapsed")
    }

    private func navigateHelp(_ name: String) -> String {
        String(format: String(localized: "viewer.pathBar.navigate.help"), name)
    }
}

// パスバーは機能層のため、macOS 26 では Liquid Glass、それ未満では Material を敷く。
// どちらもシステム外観に追従し、前景は呼び出し側の .secondary 系に任せる
private struct PathBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else {
            content.background(.bar)
        }
    }
}
