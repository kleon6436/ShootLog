import AppKit
import Foundation

struct AILabelingTarget: Sendable {
    let url: URL
    let localIdentifier: String?

    let snapshot: FileAttributesSnapshot?

    init(
        url: URL,
        localIdentifier: String?,
        snapshot: FileAttributesSnapshot? = nil
    ) {
        self.url = url
        self.localIdentifier = localIdentifier
        self.snapshot = snapshot
    }
}

protocol AILabelingImageProviding: Sendable {
    func thumbnail(for target: AILabelingTarget) async -> NSImage?
}

struct DefaultAILabelingImageProvider: AILabelingImageProviding {
    static let shared = DefaultAILabelingImageProvider(
        snapshotAwareProxyImageLoader: { url, snapshot in
            await ImageLoader.shared.proxyImage(for: url, snapshot: snapshot)
        }
    )

    private let proxyImageLoader: @Sendable (URL, FileAttributesSnapshot?) async -> NSImage?
    private let photosLibraryThumbnailLoader: @Sendable (String, CGSize) async -> NSImage?

    init(
        proxyImageLoader: @escaping @Sendable (URL) async -> NSImage? = { url in
            await ImageLoader.shared.proxyImage(for: url, snapshot: nil)
        },
        photosLibraryThumbnailLoader: @escaping @Sendable (
            String, CGSize
        ) async -> NSImage? = { localIdentifier, targetSize in
            await PhotosLibraryThumbnailProvider.shared.thumbnail(
                forLocalIdentifier: localIdentifier,
                targetSize: targetSize
            )
        }
    ) {
        self.proxyImageLoader = { url, _ in await proxyImageLoader(url) }
        self.photosLibraryThumbnailLoader = photosLibraryThumbnailLoader
    }

    private init(
        snapshotAwareProxyImageLoader: @escaping @Sendable (URL, FileAttributesSnapshot?) async -> NSImage?,
        photosLibraryThumbnailLoader: @escaping @Sendable (
            String, CGSize
        ) async -> NSImage? = { localIdentifier, targetSize in
            await PhotosLibraryThumbnailProvider.shared.thumbnail(
                forLocalIdentifier: localIdentifier,
                targetSize: targetSize
            )
        }
    ) {
        self.proxyImageLoader = snapshotAwareProxyImageLoader
        self.photosLibraryThumbnailLoader = photosLibraryThumbnailLoader
    }

    func thumbnail(for target: AILabelingTarget) async -> NSImage? {
        guard let localIdentifier = target.localIdentifier else {
            return await proxyImageLoader(target.url, target.snapshot)
        }
        if FileManager.default.fileExists(atPath: target.url.path) {
            return await proxyImageLoader(target.url, nil)
        }
        return await photosLibraryThumbnailLoader(
            localIdentifier,
            CGSize(width: 480, height: 480)
        )
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
    static let currentSchemaVersion = 2
    private static let decodeThrottle = ImageDecodeThrottle(maxConcurrent: 2)

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
        let orderedTargets = PrioritizedBatchRunner.prioritized(targets, around: selectedIndex)
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

    private static func generate(
        _ targets: [AILabelingTarget],
        imageProvider: any AILabelingImageProviding,
        classifier: any AILabelingClassifying,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, VisionLabelClassification?) -> Void
    ) async -> Bool {
        await PrioritizedBatchRunner.run(
            items: targets,
            maxWorkers: max(2, ProcessInfo.processInfo.activeProcessorCount - 2),
            progress: progress,
            process: { target in
                let result = await Self.classify(
                    target,
                    imageProvider: imageProvider,
                    classifier: classifier
                )
                guard !Task.isCancelled else { return false }
                onResult(target.url, result)
                return true
            }
        )
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
