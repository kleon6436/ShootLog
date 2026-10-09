import Foundation
import Testing

@testable import ShootLog

/// `ImageDecodeThrottle` の同時実行数制限・キャンセル・スロットの受け渡し。
struct ImageDecodeThrottleTests {

    /// 待機タスクがスロットを取得できたかを記録する。
    private actor AcquireFlag {
        private(set) var isAcquired = false
        func markAcquired() { isAcquired = true }
    }

    /// スロット待ちに入ったタスク。取得できた時点でフラグを立てる。
    private func startWaiter(on throttle: ImageDecodeThrottle, flag: AcquireFlag) -> Task<Void, Error> {
        Task {
            try await throttle.acquire()
            await flag.markAcquired()
        }
    }

    /// 条件が満たされるまでポーリングする（最大 2 秒）。
    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// 待機が解けていないことを確かめるための短い猶予。
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func acquireBeyondLimitWaitsUntilRelease() async throws {
        let throttle = ImageDecodeThrottle(maxConcurrent: 2)
        try await throttle.acquire()
        try await throttle.acquire()

        let flag = AcquireFlag()
        let waiter = startWaiter(on: throttle, flag: flag)
        await settle()
        #expect(await flag.isAcquired == false)

        await throttle.release()
        #expect(await waitUntil { await flag.isAcquired })
        try await waiter.value
    }

    @Test func cancelledWaiterThrowsAndDoesNotConsumeSlot() async throws {
        let throttle = ImageDecodeThrottle(maxConcurrent: 1)
        try await throttle.acquire()

        let flag = AcquireFlag()
        let waiter = startWaiter(on: throttle, flag: flag)
        await settle()
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await flag.isAcquired == false)

        // キャンセルされた待機者へはスロットが渡らないので、解放後すぐに取得できる。
        await throttle.release()
        try await throttle.acquire()
    }

    @Test func releaseHandsSlotToWaiterWithoutFreeingIt() async throws {
        let throttle = ImageDecodeThrottle(maxConcurrent: 1)
        try await throttle.acquire()

        let firstFlag = AcquireFlag()
        let first = startWaiter(on: throttle, flag: firstFlag)
        await settle()
        await throttle.release()
        #expect(await waitUntil { await firstFlag.isAcquired })
        try await first.value

        // スロットは待機者へ受け渡されたので、上限 1 のまま次の取得は待たされる。
        let secondFlag = AcquireFlag()
        let second = startWaiter(on: throttle, flag: secondFlag)
        await settle()
        #expect(await secondFlag.isAcquired == false)

        await throttle.release()
        #expect(await waitUntil { await secondFlag.isAcquired })
        try await second.value
    }

    /// スロットを取得した順番を記録する。
    private actor AcquireOrder {
        private(set) var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }

    @Test func releaseHandsSlotsToWaitersInArrivalOrder() async throws {
        let throttle = ImageDecodeThrottle(maxConcurrent: 1)
        try await throttle.acquire()

        let order = AcquireOrder()
        var waiters: [Task<Void, Error>] = []
        // 待機列への到着順を確定させるため、1件ずつ待機に入ったのを待ってから次を起動する。
        for index in 0..<5 {
            waiters.append(Task {
                try await throttle.acquire()
                await order.append(index)
            })
            await settle()
        }

        // 途中の待機者をキャンセルしても、残りの順序は崩れない。
        let cancelledWaiter = waiters[2]
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledWaiter.value }

        for expectedCount in 1...4 {
            await throttle.release()
            #expect(await waitUntil { await order.values.count == expectedCount })
        }
        #expect(await order.values == [0, 1, 3, 4])
        for index in [0, 1, 3, 4] {
            try await waiters[index].value
        }
    }
}
