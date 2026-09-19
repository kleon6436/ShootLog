import AppKit
import Foundation
import Testing

@testable import ShootLog

struct PhotoQualityDiagnosisGeneratorTests {

    @Test func diagnosesEveryTargetAndReportsCompletion() async {
        let targets = makeTargets(count: 4, prefix: "complete")
        let generator = PhotoQualityDiagnosisGenerator(
            imageProvider: RecordingQualityDiagnosisImageProvider(),
            diagnoser: StubPhotoQualityDiagnosing()
        )
        let progress = QualityDiagnosisProgressRecorder()
        let results = QualityDiagnosisResultRecorder()

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
        let provider = RecordingQualityDiagnosisImageProvider(delay: .milliseconds(100))
        let generator = PhotoQualityDiagnosisGenerator(
            imageProvider: provider,
            diagnoser: StubPhotoQualityDiagnosing()
        )
        let firstResults = QualityDiagnosisResultRecorder()
        let secondResults = QualityDiagnosisResultRecorder()
        let secondProgress = QualityDiagnosisProgressRecorder()

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
        let generator = PhotoQualityDiagnosisGenerator(
            imageProvider: RecordingQualityDiagnosisImageProvider(nilURLs: [failedURL]),
            diagnoser: StubPhotoQualityDiagnosing()
        )
        let progress = QualityDiagnosisProgressRecorder()
        let results = QualityDiagnosisResultRecorder()

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
        let provider = RecordingQualityDiagnosisImageProvider(delay: .milliseconds(100))
        let generator = PhotoQualityDiagnosisGenerator(
            imageProvider: provider,
            diagnoser: StubPhotoQualityDiagnosing()
        )
        let results = QualityDiagnosisResultRecorder()

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

    @Test func startingImmediatelyAfterCancelDoesNotLeakPreviousResults() async {
        let firstTargets = makeTargets(count: 50, prefix: "leaky-first")
        let secondTargets = makeTargets(count: 3, prefix: "leaky-second")
        let provider = RecordingQualityDiagnosisImageProvider(delay: .milliseconds(80))
        let generator = PhotoQualityDiagnosisGenerator(
            imageProvider: provider,
            diagnoser: StubPhotoQualityDiagnosing()
        )
        let firstResults = QualityDiagnosisResultRecorder()
        let secondResults = QualityDiagnosisResultRecorder()
        let secondProgress = QualityDiagnosisProgressRecorder()

        await generator.start(
            targets: firstTargets,
            around: nil,
            progress: { _, _ in },
            onResult: { url, result in firstResults.record(url: url, result: result) }
        )
        #expect(await wait { await provider.requestedCount() > 0 })

        // start() 内部で cancel() されるため、明示的な cancel() 呼び出しは不要な経路も検証する
        await generator.start(
            targets: secondTargets,
            around: nil,
            progress: { done, total in secondProgress.record(done: done, total: total) },
            onResult: { url, result in secondResults.record(url: url, result: result) }
        )

        #expect(await wait { secondProgress.didFinish(total: secondTargets.count) })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(firstResults.count() == 0)
        #expect(secondResults.count() == secondTargets.count)
    }

    private func makeTargets(count: Int, prefix: String) -> [AILabelingTarget] {
        (0..<count).map { index in
            AILabelingTarget(
                url: URL(fileURLWithPath: "/tmp/quality-diagnosis-\(prefix)-\(index).jpg"),
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

private struct StubPhotoQualityDiagnosing: PhotoQualityDiagnosing {
    func diagnose(_: NSImage) -> PhotoQualityDiagnosis? {
        PhotoQualityDiagnosis(
            aestheticsScore: 0.5,
            isUtility: false,
            faceQualityScore: nil,
            exposureBias: 0.0,
            sharpnessScore: 0.5,
            compositionOffsetScore: 0.0
        )
    }
}

private actor RecordingQualityDiagnosisImageProvider: AILabelingImageProviding {
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

private final class QualityDiagnosisProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Int, Int)] = []

    func record(done: Int, total: Int) {
        lock.withLock { events.append((done, total)) }
    }

    func didFinish(total: Int) -> Bool {
        lock.withLock { events.contains { $0 == (total, total) } }
    }
}

private final class QualityDiagnosisResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(URL, PhotoQualityDiagnosis?)] = []

    func record(url: URL, result: PhotoQualityDiagnosis?) {
        lock.withLock { events.append((url, result)) }
    }

    func count() -> Int {
        lock.withLock { events.count }
    }

    func urls() -> Set<URL> {
        lock.withLock { Set(events.map(\.0)) }
    }

    func result(for url: URL) -> PhotoQualityDiagnosis? {
        lock.withLock { events.first { $0.0 == url }?.1 ?? nil }
    }

    func contains(url: URL) -> Bool {
        lock.withLock { events.contains { $0.0 == url } }
    }
}
