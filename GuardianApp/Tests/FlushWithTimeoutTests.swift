import XCTest

final class FlushWithTimeoutTests: XCTestCase {
    func testReturnsEarlyWhenFlushIsFast() async {
        let clock = ManualClock()
        let done = CallLatch()
        await flushWithTimeout(.seconds(3), clock: clock) { done.increment() }
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(clock.sleeperCount, 0, "the timeout sleeper is cancelled")
    }

    func testReturnsAtTheTimeoutWhenFlushHangs() async {
        let clock = ManualClock()
        let started = CallLatch()
        let task = Task {
            await flushWithTimeout(.seconds(3), clock: clock) {
                started.increment()
                // Ignores cancellation, like a network call that never returns.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        await started.wait(for: 1)
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(3))
        await task.value
    }
}
