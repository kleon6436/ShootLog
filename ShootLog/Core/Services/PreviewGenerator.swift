import Foundation

/// 開いたフォルダのプロキシを、選択写真の近傍から低優先度で生成する。
actor PreviewGenerator {
    static let shared = PreviewGenerator()

    private static let evictionInterval = 100

    private let store: any PreviewProxyProviding
    private var generationTask: Task<Void, Never>?
    private var activeBatchID: UUID?
    private var activeProgress: (@Sendable (Int, Int) -> Void)?

    init(store: any PreviewProxyProviding = PreviewCacheStore.shared) {
        self.store = store
    }

    /// 生成対象を受け取り、選択中インデックス近傍を優先して順に生成する。
    /// 既存の実行中バッチはキャンセルして置き換える。
    func start(
        urls: [URL],
        snapshots: [URL: FileAttributesSnapshot] = [:],
        around selectedIndex: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) {
        cancel()

        let batchID = UUID()
        activeBatchID = batchID
        activeProgress = progress
        let orderedURLs = PrioritizedBatchRunner.prioritized(urls, around: selectedIndex)
        let store = store
        generationTask = Task.detached(priority: .utility) { [weak self] in
            _ = await Self.generate(
                orderedURLs,
                snapshots: snapshots,
                store: store,
                progress: progress
            )
            guard !Task.isCancelled else { return }
            await self?.finish(batchID: batchID)
        }
    }

    /// 実行中バッチを打ち切る。フォルダ切替・クローズで呼ぶ。
    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        activeBatchID = nil
        activeProgress?(0, 0)
        activeProgress = nil
    }

    private func finish(batchID: UUID) {
        guard activeBatchID == batchID, !Task.isCancelled else { return }
        generationTask = nil
        activeBatchID = nil
        activeProgress = nil
    }

    private static func generate(
        _ urls: [URL],
        snapshots: [URL: FileAttributesSnapshot],
        store: any PreviewProxyProviding,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> Bool {
        await PrioritizedBatchRunner.run(
            items: urls,
            maxWorkers: max(2, ProcessInfo.processInfo.activeProcessorCount - 2),
            progress: progress,
            onCompleted: { completed in
                if completed.isMultiple(of: evictionInterval) {
                    await store.evictToLimit()
                }
            },
            onFinished: {
                await store.evictToLimit()
            },
            process: { url in
                await store.generate(for: url, snapshot: snapshots[url])
            }
        )
    }
}
