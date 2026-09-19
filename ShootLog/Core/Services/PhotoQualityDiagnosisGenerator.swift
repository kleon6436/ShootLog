import AppKit
import Foundation

protocol PhotoQualityDiagnosing: Sendable {
    func diagnose(_ image: NSImage) -> PhotoQualityDiagnosis?
}

struct VisionPhotoQualityDiagnoser: PhotoQualityDiagnosing {
    static let shared = VisionPhotoQualityDiagnoser()

    func diagnose(_ image: NSImage) -> PhotoQualityDiagnosis? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return PhotoQualityDiagnoser.diagnose(cgImage)
    }
}

/// 開いたフォルダの写真を、選択写真の近傍から低優先度で画質診断する。
///
/// 画像の解決は `AILabelingGenerator` と同じ `AILabelingImageProviding`
/// （フォルダ写真・エクスポート済みiCloud写真は3200pxプロキシ、未エクスポートは軽量サムネイル）を共有する。
actor PhotoQualityDiagnosisGenerator {
    static let shared = PhotoQualityDiagnosisGenerator()
    static let currentSchemaVersion = 1
    // 被写体認識と同時に走るため、CPU/GPU競合が体感速度に出るなら両者でのスロットル統合を検討する。
    private static let decodeThrottle = AIBackgroundDecodeThrottle(maxConcurrent: 2)

    private let imageProvider: any AILabelingImageProviding
    private let diagnoser: any PhotoQualityDiagnosing

    private var generationTask: Task<Void, Never>?
    private var activeBatchID: UUID?
    private var activeProgress: (@Sendable (Int, Int) -> Void)?

    init(
        imageProvider: any AILabelingImageProviding = DefaultAILabelingImageProvider.shared,
        diagnoser: any PhotoQualityDiagnosing = VisionPhotoQualityDiagnoser.shared
    ) {
        self.imageProvider = imageProvider
        self.diagnoser = diagnoser
    }

    /// 診断対象を受け取り、選択中インデックス近傍を優先して診断する。
    /// 既存の実行中バッチはキャンセルして置き換える。
    func start(
        targets: [AILabelingTarget],
        around selectedIndex: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, PhotoQualityDiagnosis?) -> Void
    ) {
        cancel()

        let batchID = UUID()
        activeBatchID = batchID
        activeProgress = progress
        let orderedTargets = Self.prioritizedTargets(targets, around: selectedIndex)
        let imageProvider = self.imageProvider
        let diagnoser = self.diagnoser
        generationTask = Task.detached(priority: .utility) { [weak self] in
            _ = await Self.generate(
                orderedTargets,
                imageProvider: imageProvider,
                diagnoser: diagnoser,
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
        diagnoser: any PhotoQualityDiagnosing,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, PhotoQualityDiagnosis?) -> Void
    ) async -> Bool {
        let total = targets.count
        guard total > 0 else {
            progress(0, 0)
            return true
        }

        guard !Task.isCancelled else { return false }
        let firstTarget = targets[0]
        let firstResult = await Self.diagnose(
            firstTarget,
            imageProvider: imageProvider,
            diagnoser: diagnoser
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
                    let result = await Self.diagnose(
                        target,
                        imageProvider: imageProvider,
                        diagnoser: diagnoser
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
                        let result = await Self.diagnose(
                            target,
                            imageProvider: imageProvider,
                            diagnoser: diagnoser
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

    private static func diagnose(
        _ target: AILabelingTarget,
        imageProvider: any AILabelingImageProviding,
        diagnoser: any PhotoQualityDiagnosing
    ) async -> PhotoQualityDiagnosis? {
        do {
            try await decodeThrottle.acquire()
        } catch {
            return nil
        }

        let image = await imageProvider.thumbnail(for: target)
        await decodeThrottle.release()

        guard let image else { return nil }
        return diagnoser.diagnose(image)
    }
}
