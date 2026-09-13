import Foundation

protocol EXIFBatchReading: Sendable {
    func readEXIFBatch(
        from urls: [URL],
        snapshots: [URL: FileAttributesSnapshot],
        maxConcurrency: Int
    ) async -> [URL: EXIFInfo]
}

/// 開いたフォルダのローカル写真のEXIFを低優先度で先読みする。
actor EXIFPrefetcher {
    static let shared = EXIFPrefetcher()

    private let reader: any EXIFBatchReading
    private var prefetchTask: Task<Void, Never>?
    private var activeBatchID: UUID?
    private var activeProgress: (@Sendable (Int, Int) -> Void)?

    init(reader: any EXIFBatchReading = EXIFService.shared) {
        self.reader = reader
    }

    /// EXIF未取得のURLをチャンク単位で読み取り、結果を呼び出し側へ返す。
    /// 実行中のバッチはキャンセルして置き換える。
    func start(
        urls: [URL],
        snapshots: [URL: FileAttributesSnapshot] = [:],
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, EXIFInfo) -> Void
    ) {
        cancel()

        let batchID = UUID()
        activeBatchID = batchID
        activeProgress = progress
        let batchSize = ContentViewModel.photoStagingChunkSize
        let reader = self.reader
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            _ = await Self.prefetch(
                urls,
                snapshots: snapshots,
                batchSize: batchSize,
                reader: reader,
                progress: progress,
                onResult: onResult
            )
            guard !Task.isCancelled else { return }
            await self?.finish(batchID: batchID)
        }
    }

    /// 実行中の先読みを打ち切る。フォルダ切替・クローズで呼ぶ。
    func cancel() {
        prefetchTask?.cancel()
        prefetchTask = nil
        activeBatchID = nil
        activeProgress?(0, 0)
        activeProgress = nil
    }

    private func finish(batchID: UUID) {
        guard activeBatchID == batchID, !Task.isCancelled else { return }
        prefetchTask = nil
        activeBatchID = nil
        activeProgress = nil
    }

    private static func prefetch(
        _ urls: [URL],
        snapshots: [URL: FileAttributesSnapshot],
        batchSize: Int,
        reader: any EXIFBatchReading,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, EXIFInfo) -> Void
    ) async -> Bool {
        let total = urls.count
        guard total > 0 else {
            progress(0, 0)
            return true
        }

        let effectiveBatchSize = max(1, batchSize)
        var completed = 0
        while completed < total {
            guard !Task.isCancelled else { return false }
            let end = min(completed + effectiveBatchSize, total)
            let chunk = Array(urls[completed..<end])
            let results = await reader.readEXIFBatch(
                from: chunk,
                snapshots: snapshots,
                maxConcurrency: EXIFService.recommendedBatchConcurrency(for: chunk.first)
            )
            guard !Task.isCancelled else { return false }

            for (url, exif) in results {
                guard !Task.isCancelled else { return false }
                onResult(url, exif)
            }

            completed = end
            progress(completed, total)
            await Task.yield()
        }
        return true
    }
}

extension EXIFService: EXIFBatchReading {}
