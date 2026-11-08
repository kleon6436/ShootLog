import SwiftUI

// サイドバー上部のフォルダツリー（見出し行＋ツリー本体）。
// 高さは呼び出し側（SidebarModeView）が AppStorage で持ち、FolderTreeResizeHandle で変える。
// 折りたたみ時も本体を破棄せず高さ0にして、展開状態とスクロール位置を保つ
struct FolderTreeSection: View {
    let vm: SidebarViewModel
    @Binding var isCollapsed: Bool
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            header
            treeList
                .frame(height: isCollapsed ? 0 : height)
                .clipped()
                .accessibilityHidden(isCollapsed)
        }
        // View の生成時点の初回分と、fullscreen 中に別ルートを開いてから戻った場合の両方を拾う
        // （.onChange は初期値で発火しないため使わない。setRoot は冪等）
        .task(id: vm.navigationBoundaryURL) {
            vm.syncFolderTreeRoot()
        }
        // パスバー・⌘↑ など、ツリー以外の経路で移動したときも該当行まで展開する
        .onChange(of: vm.currentFolderURL) { _, newValue in
            guard let newValue else { return }
            vm.folderTree.reveal(newValue)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
        } label: {
            HStack(spacing: Spacing.xSmall) {
                Text("sidebar.folderTree.title")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.xLarge)
            .padding(.vertical, Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "sidebar.folderTree.expand" : "sidebar.folderTree.collapse")
        .accessibilityLabel(isCollapsed ? "sidebar.folderTree.expand" : "sidebar.folderTree.collapse")
        .contextMenu {
            if vm.treeAccessURL != nil {
                Button("contextMenu.folderTree.revokeAccess") { vm.revokeTreeAccess() }
            }
        }
    }

    private var treeList: some View {
        ScrollViewReader { proxy in
            // List(selection:) の選択は使わない。macOS の List は DisclosureGroup の行の選択描画を
            // 行の挿入・移動（根の切り替えや展開）の際に取り残し、選択行の名前が二重に重なって見えるため。
            // 表示フォルダの強調とクリックでの移動は FolderTreeRow 側で受け持つ
            List {
                if let root = vm.folderTree.root {
                    FolderTreeRow(
                        tree: vm.folderTree,
                        url: root,
                        openedRootURL: openedRootURL,
                        highlightedURL: vm.highlightedFolderURL,
                        isTreeRoot: true
                    )
                }
            }
            .listStyle(.sidebar)
            .onChange(of: vm.highlightedFolderURL) { _, newValue in
                guard let newValue else { return }
                withAnimation { proxy.scrollTo(newValue) }
            }
            // 行は非同期の読み込みで揃うため、移動時の scrollTo だけでは届かないことがある
            .onChange(of: vm.folderTree.scrollRequest) { _, newValue in
                guard let newValue else { return }
                withAnimation { proxy.scrollTo(newValue.url) }
            }
        }
    }

    private var openedRootURL: URL? {
        vm.rootFolderURL.map(FolderTreeViewModel.normalized)
    }
}

// ツリーの1行。展開済みなら子フォルダの行を再帰的に並べる
private struct FolderTreeRow: View {
    let tree: FolderTreeViewModel
    let url: URL
    let openedRootURL: URL?
    // 表示フォルダ（またはデバウンス中の移動要求）。ツリーは独自の選択を持たず、これに一致する行を強調する
    let highlightedURL: URL?
    var isTreeRoot = false

    var body: some View {
        Group {
            // 読み込むまでは展開矢印を出し、読み込み結果が空なら消す（子の数を数える事前 I/O はしない）
            if let children = tree.children[url], children.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: isExpanded) {
                    ForEach(tree.children[url] ?? [], id: \.self) { child in
                        FolderTreeRow(
                            tree: tree,
                            url: child,
                            openedRootURL: openedRootURL,
                            highlightedURL: highlightedURL
                        )
                    }
                } label: {
                    label
                }
            }
        }
        .id(url)
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { tree.isExpanded(url) },
            set: { tree.setExpanded(url, $0) }
        )
    }

    private var name: String {
        tree.displayName(for: url)
    }

    private var isHighlighted: Bool {
        url == highlightedURL
    }

    // ツリーの根が上位フォルダのとき、開いているフォルダの行を見分けられるようにする
    private var isOpenedRootBelowTreeRoot: Bool {
        !isTreeRoot && url == openedRootURL
    }

    // ボリュームのルート（"/" や /Volumes/X）はドライブのアイコンにする。判定はパスだけで行い I/O しない
    private var symbolName: String {
        let components = url.pathComponents
        let isVolumeRoot = components == ["/"]
            || (components.count == 3 && components[1] == "Volumes")
        if isTreeRoot && isVolumeRoot { return "externaldrive" }
        return isOpenedRootBelowTreeRoot ? "folder.fill" : "folder"
    }

    private var label: some View {
        HStack(spacing: Spacing.xSmall) {
            Label {
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: symbolName)
            }
            .help(Text(verbatim: name))
            Spacer(minLength: 0)
            if tree.loading.contains(url) {
                ProgressView()
                    .controlSize(.mini)
            } else if tree.failed.contains(url) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help("sidebar.folderTree.loadFailed")
                    .accessibilityLabel("sidebar.folderTree.loadFailed")
            }
        }
        .padding(.vertical, Self.highlightVerticalInset)
        .padding(.horizontal, Self.highlightHorizontalInset)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: CornerRadius.small)
                    .fill(.quaternary)
            }
        }
        .padding(.horizontal, -Self.highlightHorizontalInset)
        .contentShape(Rectangle())
        // 行のクリックはデバウンス付きの移動要求として VM へ渡す
        .onTapGesture { tree.requestNavigate(url) }
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { tree.requestNavigate(url) }
        .accessibilityValue(isOpenedRootBelowTreeRoot ? Text("a11y.folderTree.openedRoot") : Text(verbatim: ""))
    }

    // 強調の塗りを文字の周りへ広げる量
    private static let highlightVerticalInset: CGFloat = 2
    private static let highlightHorizontalInset: CGFloat = 6
}

// ツリーと写真一覧の境界。ドラッグでツリーの高さを変え、終了時に保存する。
// VoiceOver の調整アクションでも高さを変えられる（BeforeAfterSplitView の境界移動と同じ流儀）
struct FolderTreeResizeHandle: View {
    // ドラッグ中の高さ（確定前）。nil なら保存値を使う
    @Binding var liveHeight: CGFloat?
    let height: CGFloat
    let range: ClosedRange<CGFloat>
    let onCommit: (CGFloat) -> Void

    // ハンドルの当たり判定の高さ
    static let thickness: CGFloat = 6
    // VoiceOver の調整アクション1回あたりの変化量
    private let accessibilityStep: CGFloat = 20

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        Divider()
            .frame(maxWidth: .infinity)
            .frame(height: Self.thickness)
            .contentShape(Rectangle())
            // カーソルの push/pop を自前で持つと、ホバー中にハンドルが消えたとき pop されずに残るため、
            // 宣言的なポインタスタイルに任せる
            .pointerStyle(.rowResize)
            // ハンドル自身が liveHeight に合わせて動くため、ローカル座標だと移動量が揺れる。
            // ウィンドウ基準の移動量を、ドラッグ開始時の高さに足して求める
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? height
                        dragStartHeight = start
                        liveHeight = clamped(start + value.translation.height)
                    }
                    .onEnded { value in
                        let start = dragStartHeight ?? height
                        dragStartHeight = nil
                        liveHeight = nil
                        onCommit(clamped(start + value.translation.height))
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("sidebar.folderTree.resize")
            .accessibilityValue(Text(Int(height), format: .number))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onCommit(clamped(height + accessibilityStep))
                case .decrement:
                    onCommit(clamped(height - accessibilityStep))
                @unknown default:
                    break
                }
            }
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
