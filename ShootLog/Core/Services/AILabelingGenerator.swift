import AppKit
import Foundation

struct AILabelingTarget: Sendable {
    let url: URL
    let localIdentifier: String?
}

protocol AILabelingImageProviding: Sendable {
    func thumbnail(for target: AILabelingTarget) async -> NSImage?
}

struct DefaultAILabelingImageProvider: AILabelingImageProviding {
    static let shared = DefaultAILabelingImageProvider()

    func thumbnail(for target: AILabelingTarget) async -> NSImage? {
        if let localIdentifier = target.localIdentifier {
            return await PhotosLibraryThumbnailProvider.shared.thumbnail(
                forLocalIdentifier: localIdentifier,
                targetSize: CGSize(width: 480, height: 480)
            )
        }
        return await ImageLoader.shared.thumbnail(for: target.url)
    }
}

protocol AILabelingClassifying: Sendable {
    func classify(_ image: NSImage) -> VisionLabelClassification?
}

struct VisionAILabelingClassifier: AILabelingClassifying {
    static let shared = VisionAILabelingClassifier()

    func classify(_ image: NSImage) -> VisionLabelClassification? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return VisionLabelClassifier.classify(cgImage)
    }
}

/// 開いたフォルダの写真を、選択写真の近傍から低優先度で分類する。
actor AILabelingGenerator {
    static let shared = AILabelingGenerator()
    private static let decodeThrottle = AILabelingDecodeThrottle(maxConcurrent: 2)

    private let imageProvider: any AILabelingImageProviding
    private let classifier: any AILabelingClassifying

    private var generationTask: Task<Void, Never>?
    private var activeBatchID: UUID?
    private var activeProgress: (@Sendable (Int, Int) -> Void)?

    init(
        imageProvider: any AILabelingImageProviding = DefaultAILabelingImageProvider.shared,
        classifier: any AILabelingClassifying = VisionAILabelingClassifier.shared
    ) {
        self.imageProvider = imageProvider
        self.classifier = classifier
    }

    /// 分類対象を受け取り、選択中インデックス近傍を優先して分類する。
    /// 既存の実行中バッチはキャンセルして置き換える。
    func start(
        targets: [AILabelingTarget],
        around selectedIndex: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, VisionLabelClassification?) -> Void
    ) {
        cancel()

        let batchID = UUID()
        activeBatchID = batchID
        activeProgress = progress
        let orderedTargets = Self.prioritizedTargets(targets, around: selectedIndex)
        let imageProvider = self.imageProvider
        let classifier = self.classifier
        generationTask = Task.detached(priority: .utility) { [weak self] in
            _ = await Self.generate(
                orderedTargets,
                imageProvider: imageProvider,
                classifier: classifier,
                progress: progress,
                onResult: onResult
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

    private static func prioritizedTargets(
        _ targets: [AILabelingTarget],
        around selectedIndex: Int?
    ) -> [AILabelingTarget] {
        guard let selectedIndex, targets.indices.contains(selectedIndex) else { return targets }

        var result: [AILabelingTarget] = []
        result.reserveCapacity(targets.count)
        for distance in 0..<targets.count {
            let next = selectedIndex + distance
            if targets.indices.contains(next) {
                result.append(targets[next])
            }

            guard distance > 0 else { continue }
            let previous = selectedIndex - distance
            if targets.indices.contains(previous) {
                result.append(targets[previous])
            }
        }
        return result
    }

    private static func generate(
        _ targets: [AILabelingTarget],
        imageProvider: any AILabelingImageProviding,
        classifier: any AILabelingClassifying,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, VisionLabelClassification?) -> Void
    ) async -> Bool {
        let total = targets.count
        guard total > 0 else {
            progress(0, 0)
            return true
        }

        guard !Task.isCancelled else { return false }
        let firstTarget = targets[0]
        let firstResult = await Self.classify(
            firstTarget,
            imageProvider: imageProvider,
            classifier: classifier
        )
        guard !Task.isCancelled else { return false }
        onResult(firstTarget.url, firstResult)

        var completed = 1
        progress(completed, total)
        var nextIndex = 1
        let workerCount = min(
            total - nextIndex,
            max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        )

        guard workerCount > 0 else { return true }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<workerCount {
                let target = targets[nextIndex]
                nextIndex += 1
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return false }
                    let result = await Self.classify(
                        target,
                        imageProvider: imageProvider,
                        classifier: classifier
                    )
                    guard !Task.isCancelled else { return false }
                    onResult(target.url, result)
                    await Task.yield()
                    return true
                }
            }

            while let _ = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }

                completed += 1
                progress(completed, total)
                if nextIndex < total {
                    let target = targets[nextIndex]
                    nextIndex += 1
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return false }
                        let result = await Self.classify(
                            target,
                            imageProvider: imageProvider,
                            classifier: classifier
                        )
                        guard !Task.isCancelled else { return false }
                        onResult(target.url, result)
                        await Task.yield()
                        return true
                    }
                }
            }
        }

        guard !Task.isCancelled else { return false }
        return completed == total
    }

    private static func classify(
        _ target: AILabelingTarget,
        imageProvider: any AILabelingImageProviding,
        classifier: any AILabelingClassifying
    ) async -> VisionLabelClassification? {
        do {
            try await decodeThrottle.acquire()
        } catch {
            return nil
        }

        let image = await imageProvider.thumbnail(for: target)
        await decodeThrottle.release()

        guard let image else { return nil }
        return classifier.classify(image)
    }
}

private actor AILabelingDecodeThrottle {
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async throws {
        guard active >= maxConcurrent else {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    func release() {
        if let (id, continuation) = waiters.first {
            waiters.removeValue(forKey: id)
            continuation.resume()
        } else {
            active -= 1
        }
    }
}
