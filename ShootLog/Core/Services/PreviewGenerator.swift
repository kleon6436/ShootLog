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
        around selectedIndex: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) {
        cancel()

        let batchID = UUID()
        activeBatchID = batchID
        activeProgress = progress
        let orderedURLs = Self.prioritizedURLs(urls, around: selectedIndex)
        let store = store
        generationTask = Task.detached(priority: .utility) { [weak self] in
            await Self.generate(
                orderedURLs,
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

    private static func prioritizedURLs(_ urls: [URL], around selectedIndex: Int?) -> [URL] {
        guard let selectedIndex, urls.indices.contains(selectedIndex) else { return urls }

        var result: [URL] = []
        result.reserveCapacity(urls.count)
        for distance in 0..<urls.count {
            let next = selectedIndex + distance
            if urls.indices.contains(next) {
                result.append(urls[next])
            }

            guard distance > 0 else { continue }
            let previous = selectedIndex - distance
            if urls.indices.contains(previous) {
                result.append(urls[previous])
            }
        }
        return result
    }

    private static func generate(
        _ urls: [URL],
        store: any PreviewProxyProviding,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> Bool {
        let total = urls.count
        guard total > 0 else {
            progress(0, 0)
            return true
        }

        guard !Task.isCancelled else { return false }
        _ = await store.generate(for: urls[0])
        guard !Task.isCancelled else { return false }

        var completed = 1
        progress(completed, total)
        var nextIndex = 1
        let workerCount = min(
            total - nextIndex,
            max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        )

        guard workerCount > 0 else {
            await store.evictToLimit()
            return true
        }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<workerCount {
                let url = urls[nextIndex]
                nextIndex += 1
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return false }
                    let didGenerate = await store.generate(for: url)
                    await Task.yield()
                    return didGenerate
                }
            }

            while let _ = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }

                completed += 1
                progress(completed, total)
                if completed.isMultiple(of: evictionInterval) {
                    await store.evictToLimit()
                }

                if nextIndex < total {
                    let url = urls[nextIndex]
                    nextIndex += 1
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return false }
                        let didGenerate = await store.generate(for: url)
                        await Task.yield()
                        return didGenerate
                    }
                }
            }
        }

        guard !Task.isCancelled else { return false }
        await store.evictToLimit()
        return completed == total
    }
}
