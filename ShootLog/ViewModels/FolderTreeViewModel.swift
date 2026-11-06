import Foundation

// サイドバー上部のフォルダツリーの状態。所有者は SidebarViewModel。
// 列挙は展開したフォルダだけを遅延して行い、全階層を事前には走査しない（NAS 上の巨大なツリー対策）。
// 選択中フォルダの真実源は ContentViewModel.currentFolderURL で、ツリーは独自の選択を持たない
@Observable
@MainActor
final class FolderTreeViewModel {
    // 直下のサブフォルダを返す列挙処理。テストではスタブへ差し替える
    typealias Enumerator = @Sendable (URL) async throws -> [URL]
    // 実際のフォルダ移動。通常は ContentViewModel.navigateToFolder へつなぐ
    typealias Navigator = @MainActor (URL) async -> Void

    // 既定の列挙処理。MainActor 上で同期 I/O をしないよう detached で実行する
    nonisolated static let repositoryEnumerator: Enumerator = { url in
        try await Task.detached(priority: .utility) {
            try FolderTreeRepository.childFolders(of: url)
        }.value
    }

    // 連続クリックで読み込みの起動とキャンセルが連鎖しないよう、移動要求はこの時間だけまとめる
    nonisolated static let defaultNavigationDebounce: Duration = .milliseconds(150)

    private(set) var root: URL?
    // 読み込み済みのフォルダ → 直下のサブフォルダ。未読み込みのフォルダはキーを持たない
    private(set) var children: [URL: [URL]] = [:]
    private(set) var expanded: Set<URL> = []
    private(set) var loading: Set<URL> = []
    private(set) var failed: Set<URL> = []
    // デバウンス待ち・移動処理中の行。ハイライトを実際の移動より先に進めるために使う
    private(set) var pendingSelection: URL?

    @ObservationIgnored private let enumerate: Enumerator
    @ObservationIgnored private let navigate: Navigator
    @ObservationIgnored private let navigationDebounce: Duration
    // ルート切替後に遅れて届いた列挙結果・移動要求を捨てるための世代番号
    @ObservationIgnored private var generation = 0
    // 最新の移動要求の番号。古い要求の完了で pendingSelection を消さないために使う
    @ObservationIgnored private var navigationRequestID = 0
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    // 実行中の列挙 Task。完了を待てるよう番号で持ち、終わったものから外す
    @ObservationIgnored private var loadTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextLoadTaskID = 0

    init(
        enumerate: @escaping Enumerator = FolderTreeViewModel.repositoryEnumerator,
        navigationDebounce: Duration = FolderTreeViewModel.defaultNavigationDebounce,
        navigate: @escaping Navigator
    ) {
        self.enumerate = enumerate
        self.navigationDebounce = navigationDebounce
        self.navigate = navigate
    }

    // URL を辞書キー・比較用に正規化する。列挙結果のディレクトリ URL は末尾スラッシュ付きで返り、
    // NSOpenPanel 等の URL と文字列が揃わないため、標準化したうえでディレクトリ表記へ統一する
    static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    // MARK: - ルート

    // 同じルートなら何もしない（View の再生成やモード往復で状態を失わないため）。
    // 違えば全状態をリセットし、ルート直下を読み込んで展開する
    func setRoot(_ url: URL?) {
        let newRoot = url.map(Self.normalized)
        guard newRoot != root else { return }
        generation &+= 1
        navigationTask?.cancel()
        navigationTask = nil
        root = newRoot
        children = [:]
        expanded = []
        loading = []
        failed = []
        pendingSelection = nil
        guard let newRoot else { return }
        expanded.insert(newRoot)
        load(newRoot)
    }

    // MARK: - 展開

    func isExpanded(_ url: URL) -> Bool {
        expanded.contains(Self.normalized(url))
    }

    // 展開するたびに直下を読み込み直す。外部での変更を手動で反映する手段を兼ねる
    // （フォルダ内容の自動変更検知はしない規約のため）
    func setExpanded(_ url: URL, _ isExpanded: Bool) {
        let key = Self.normalized(url)
        if isExpanded {
            guard !expanded.contains(key) else { return }
            expanded.insert(key)
            load(key)
        } else {
            expanded.remove(key)
        }
    }

    func toggleExpanded(_ url: URL) {
        setExpanded(url, !isExpanded(url))
    }

    // ルートから対象の親までを展開する（パスバー・⌘↑ で移動したときにツリーの該当行を見せるため）
    func reveal(_ url: URL) {
        guard let root else { return }
        let target = Self.normalized(url)
        guard FolderPathComponents.isFolder(target, inside: root) else { return }
        var ancestors: [URL] = []
        var current = target
        while !FolderPathComponents.isSameFolder(current, root) {
            current = Self.normalized(current.deletingLastPathComponent())
            ancestors.append(current)
        }
        for ancestor in ancestors.reversed() where !expanded.contains(ancestor) {
            expanded.insert(ancestor)
            load(ancestor)
        }
    }

    // MARK: - 移動要求

    // フォルダ移動の唯一の入口。ツリー・パスバー・⌘↑ のどこから来た要求も、後に来たものが必ず勝つよう
    // ここで1本にまとめる。ツリーの行クリックはデバウンスして最後の1件だけを渡し、
    // パスバー・⌘↑ のような単発の操作は isDebounced: false で待たずに渡す
    // （どちらでも、待機中の前の要求は取り消される）
    func requestNavigate(_ url: URL, isDebounced: Bool = true) {
        let target = Self.normalized(url)
        pendingSelection = target
        navigationRequestID &+= 1
        let requestID = navigationRequestID
        let generation = generation
        let delay: Duration? = isDebounced ? navigationDebounce : nil
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            // 移動処理自体は後続の要求でキャンセルさせない（読み込みの途中状態を残さないため）。
            // 待っている間に新しい要求が来ていれば、その要求が pendingSelection を引き継ぐ
            let navigate = self.navigate
            await Task { await navigate(target) }.value
            guard requestID == self.navigationRequestID else { return }
            self.pendingSelection = nil
        }
    }

    // 最後に受け付けた移動要求の完了を待つ（呼び出し側・テストが移動後の状態を確かめるため）
    func waitForPendingNavigation() async {
        await navigationTask?.value
    }

    // 実行中の列挙がすべて終わるまで待つ。ルート切替で破棄される旧ルートの列挙も含む
    func waitForPendingLoads() async {
        while let task = loadTasks.values.first {
            await task.value
        }
    }

    // MARK: - 読み込み

    private func load(_ url: URL) {
        guard !loading.contains(url) else { return }
        loading.insert(url)
        failed.remove(url)
        let generation = generation
        let enumerate = enumerate
        nextLoadTaskID &+= 1
        let taskID = nextLoadTaskID
        loadTasks[taskID] = Task { [weak self] in
            defer { self?.loadTasks[taskID] = nil }
            let result: Result<[URL], any Error>
            do {
                result = .success(try await enumerate(url))
            } catch {
                result = .failure(error)
            }
            guard let self, generation == self.generation else { return }
            self.loading.remove(url)
            switch result {
            case .success(let urls):
                self.children[url] = urls.map(Self.normalized)
            case .failure:
                // インライン通知のみ（行末のアイコン）。アラートは出さない
                self.failed.insert(url)
            }
        }
    }
}
