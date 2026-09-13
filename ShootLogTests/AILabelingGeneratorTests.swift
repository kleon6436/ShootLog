import AppKit
import Foundation
import Testing

@testable import ShootLog

struct AILabelingGeneratorTests {

    @Test func classifiesEveryTargetAndReportsCompletion() async {
        let targets = makeTargets(count: 4, prefix: "complete")
        let generator = AILabelingGenerator(
            imageProvider: RecordingAILabelingImageProvider(),
            classifier: StubAILabelingClassifier()
        )
        let progress = AILabelingProgressRecorder()
        let results = AILabelingResultRecorder()

        await generator.start(
            targets: targets,
            around: nil,
            progress: { done, total in progress.record(done: done, total: total) },
            onResult: { url, result in results.record(url: url, result: result) }
        )

        #expect(await wait { progress.didFinish(total: targets.count) })
        #expect(results.urls() == Set(targets.map(\.url)))
        #expect(results.count() == targets.count)
    }

    @Test func startingAgainCancelsThePreviousBatch() async {
        let firstTargets = makeTargets(count: 4, prefix: "first")
        let secondTargets = makeTargets(count: 3, prefix: "second")
        let provider = RecordingAILabelingImageProvider(delay: .milliseconds(100))
        let generator = AILabelingGenerator(
            imageProvider: provider,
            classifier: StubAILabelingClassifier()
        )
        let firstResults = AILabelingResultRecorder()
        let secondResults = AILabelingResultRecorder()
        let secondProgress = AILabelingProgressRecorder()

        await generator.start(
            targets: firstTargets,
            around: nil,
            progress: { _, _ in },
            onResult: { url, result in firstResults.record(url: url, result: result) }
        )
        #expect(await wait { await provider.requestedCount() > 0 })

        await generator.start(
            targets: secondTargets,
            around: nil,
            progress: { done, total in secondProgress.record(done: done, total: total) },
            onResult: { url, result in secondResults.record(url: url, result: result) }
        )

        #expect(await wait { secondProgress.didFinish(total: secondTargets.count) })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(firstResults.count() == 0)
        #expect(secondResults.urls() == Set(secondTargets.map(\.url)))
    }

    @Test func imageAcquisitionFailureIsReportedAsNilResult() async {
        let targets = makeTargets(count: 3, prefix: "failure")
        let failedURL = targets[1].url
        let generator = AILabelingGenerator(
            imageProvider: RecordingAILabelingImageProvider(nilURLs: [failedURL]),
            classifier: StubAILabelingClassifier()
        )
        let progress = AILabelingProgressRecorder()
        let results = AILabelingResultRecorder()

        await generator.start(
            targets: targets,
            around: nil,
            progress: { done, total in progress.record(done: done, total: total) },
            onResult: { url, result in results.record(url: url, result: result) }
        )

        #expect(await wait { progress.didFinish(total: targets.count) })
        #expect(results.contains(url: failedURL))
        #expect(results.result(for: failedURL) == nil)
        #expect(results.result(for: targets[0].url) != nil)
        #expect(results.result(for: targets[2].url) != nil)
    }

    @Test func cancelPreventsRemainingResults() async {
        let targets = makeTargets(count: 100, prefix: "cancel")
        let provider = RecordingAILabelingImageProvider(delay: .milliseconds(100))
        let generator = AILabelingGenerator(
            imageProvider: provider,
            classifier: StubAILabelingClassifier()
        )
        let results = AILabelingResultRecorder()

        await generator.start(
            targets: targets,
            around: nil,
            progress: { _, _ in },
            onResult: { url, result in results.record(url: url, result: result) }
        )
        #expect(await wait { await provider.requestedCount() > 0 })

        await generator.cancel()
        let resultCountAtCancellation = results.count()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(resultCountAtCancellation < targets.count)
        #expect(results.count() == resultCountAtCancellation)
    }

    private func makeTargets(count: Int, prefix: String) -> [AILabelingTarget] {
        (0..<count).map { index in
            AILabelingTarget(
                url: URL(fileURLWithPath: "/tmp/ai-labeling-\(prefix)-\(index).jpg"),
                localIdentifier: nil
            )
        }
    }

    private func wait(
        until condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private struct StubAILabelingClassifier: AILabelingClassifying {
    func classify(_: NSImage) -> VisionLabelClassification? {
        VisionLabelClassification(categories: [.person], rawIdentifiers: ["test"])
    }
}

private actor RecordingAILabelingImageProvider: AILabelingImageProviding {
    private let delay: Duration?
    private let nilURLs: Set<URL>
    private var requestedURLs: [URL] = []

    init(delay: Duration? = nil, nilURLs: Set<URL> = []) {
        self.delay = delay
        self.nilURLs = nilURLs
    }

    func thumbnail(for target: AILabelingTarget) async -> NSImage? {
        requestedURLs.append(target.url)
        if let delay {
            try? await Task.sleep(for: delay)
        }
        guard !Task.isCancelled, !nilURLs.contains(target.url) else { return nil }
        return NSImage(size: NSSize(width: 1, height: 1))
    }

    func requestedCount() -> Int {
        requestedURLs.count
    }
}

private final class AILabelingProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Int, Int)] = []

    func record(done: Int, total: Int) {
        lock.withLock { events.append((done, total)) }
    }

    func didFinish(total: Int) -> Bool {
        lock.withLock { events.contains { $0 == (total, total) } }
    }
}

private final class AILabelingResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(URL, VisionLabelClassification?)] = []

    func record(url: URL, result: VisionLabelClassification?) {
        lock.withLock { events.append((url, result)) }
    }

    func count() -> Int {
        lock.withLock { events.count }
    }

    func urls() -> Set<URL> {
        lock.withLock { Set(events.map(\.0)) }
    }

    func result(for url: URL) -> VisionLabelClassification? {
        lock.withLock { events.first { $0.0 == url }?.1 ?? nil }
    }

    func contains(url: URL) -> Bool {
        lock.withLock { events.contains { $0.0 == url } }
    }
}
