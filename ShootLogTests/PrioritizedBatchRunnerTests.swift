import Foundation
import Testing

@testable import ShootLog

/// バックグラウンド生成器が共有する処理ループ（`PrioritizedBatchRunner`）。
struct PrioritizedBatchRunnerTests {

    /// 複数ワーカーから呼ばれる記録を直列化する。
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var processedValues: [Int] = []
        private var progressValues: [(Int, Int)] = []
        private var completedValues: [Int] = []
        private var finishedCount = 0

        var processed: [Int] { lock.withLock { processedValues } }
        var progress: [(Int, Int)] { lock.withLock { progressValues } }
        var completed: [Int] { lock.withLock { completedValues } }
        var finished: Int { lock.withLock { finishedCount } }

        func recordProcessed(_ value: Int) { lock.withLock { processedValues.append(value) } }
        func recordProgress(_ done: Int, _ total: Int) { lock.withLock { progressValues.append((done, total)) } }
        func recordCompleted(_ value: Int) { lock.withLock { completedValues.append(value) } }
        func recordFinished() { lock.withLock { finishedCount += 1 } }
    }

    private func run(_ items: [Int], maxWorkers: Int, recorder: Recorder) async -> Bool {
        await PrioritizedBatchRunner.run(
            items: items,
            maxWorkers: maxWorkers,
            progress: { done, total in recorder.recordProgress(done, total) },
            onCompleted: { completed in recorder.recordCompleted(completed) },
            onFinished: { recorder.recordFinished() },
            process: { item in
                recorder.recordProcessed(item)
                return true
            }
        )
    }

    @Test func prioritizedOrdersByDistanceFromSelection() {
        let ordered = PrioritizedBatchRunner.prioritized([0, 1, 2, 3, 4, 5], around: 2)
        #expect(ordered == [2, 3, 1, 4, 0, 5])
    }

    @Test func prioritizedKeepsOrderWithoutValidSelection() {
        #expect(PrioritizedBatchRunner.prioritized([0, 1, 2], around: nil) == [0, 1, 2])
        #expect(PrioritizedBatchRunner.prioritized([0, 1, 2], around: 5) == [0, 1, 2])
    }

    @Test func emptyItemsReportZeroProgressWithoutFinishing() async {
        let recorder = Recorder()
        let didComplete = await run([], maxWorkers: 2, recorder: recorder)
        #expect(didComplete)
        #expect(recorder.progress.map { [$0.0, $0.1] } == [[0, 0]])
        #expect(recorder.finished == 0)
    }

    @Test func singleItemIsProcessedAloneAndFinishes() async {
        let recorder = Recorder()
        let didComplete = await run([7], maxWorkers: 2, recorder: recorder)
        #expect(didComplete)
        #expect(recorder.processed == [7])
        #expect(recorder.progress.map { [$0.0, $0.1] } == [[1, 1]])
        #expect(recorder.completed.isEmpty)
        #expect(recorder.finished == 1)
    }

    @Test func processesEveryItemWithFirstItemFirst() async {
        let recorder = Recorder()
        let items = Array(0..<20)
        let didComplete = await run(items, maxWorkers: 3, recorder: recorder)
        #expect(didComplete)
        #expect(recorder.processed.first == 0)
        #expect(recorder.processed.sorted() == items)
        #expect(recorder.progress.map(\.0) == Array(1...20))
        #expect(recorder.progress.allSatisfy { $0.1 == 20 })
        #expect(recorder.completed == Array(2...20))
        #expect(recorder.finished == 1)
    }

    @Test func cancellationStopsBeforeFinishing() async {
        let recorder = Recorder()
        let task = Task {
            await PrioritizedBatchRunner.run(
                items: Array(0..<50),
                maxWorkers: 2,
                progress: { done, total in recorder.recordProgress(done, total) },
                onFinished: { recorder.recordFinished() },
                process: { item in
                    recorder.recordProcessed(item)
                    try? await Task.sleep(for: .milliseconds(20))
                    return !Task.isCancelled
                }
            )
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let didComplete = await task.value
        #expect(!didComplete)
        #expect(recorder.finished == 0)
        #expect(recorder.processed.count < 50)
    }
}
