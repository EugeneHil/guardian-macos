import XCTest

final class ManualClockTests: XCTestCase {
    func testNowMovesOnlyOnAdvance() {
        let clock = ManualClock()
        let start = clock.now
        clock.advance(by: .seconds(3))
        XCTAssertEqual(start.duration(to: clock.now), .seconds(3))
    }

    func testSleepIsReleasedByAdvance() async throws {
        let clock = ManualClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        let sleeper = Task { try await clock.sleep(until: deadline) }
        clock.advance(by: .seconds(10))
        try await sleeper.value
    }

    func testSleepPastDeadlineReturnsImmediately() async throws {
        let clock = ManualClock()
        clock.advance(by: .seconds(5))
        try await clock.sleep(until: clock.now)
    }

    func testWaitForSleepersResumesOnceTheSleeperIsSuspended() async throws {
        let clock = ManualClock()
        XCTAssertEqual(clock.sleeperCount, 0)
        let sleeper = Task { try await clock.sleep(for: .seconds(10)) }
        await clock.waitForSleepers(1)
        XCTAssertEqual(clock.sleeperCount, 1)
        clock.advance(by: .seconds(9))
        XCTAssertEqual(clock.sleeperCount, 1)
        clock.advance(by: .seconds(1))
        XCTAssertEqual(clock.sleeperCount, 0)
        try await sleeper.value
    }

    func testWaitForSleepersReturnsWhenAlreadySatisfied() async {
        let clock = ManualClock()
        await clock.waitForSleepers(0)
        let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
        await clock.waitForSleepers(1)
        await clock.waitForSleepers(1)
        sleeper.cancel()
        _ = await sleeper.result
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testCancelledSleepThrows() async {
        let clock = ManualClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        let sleeper = Task { try await clock.sleep(until: deadline) }
        sleeper.cancel()
        let result = await sleeper.result
        XCTAssertThrowsError(try result.get())
    }
}
