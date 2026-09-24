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
}
