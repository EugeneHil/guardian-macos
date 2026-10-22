import Synchronization
import XCTest

/// Answers kernel clear calls from a script (then `.cleared`) and streams each call to the test.
private final class ScriptedClear: Sendable {
    private let script: Mutex<[CacheClearResult]>
    private let count = Mutex(0)
    private let continuation: AsyncStream<Int>.Continuation
    let stream: AsyncStream<Int>

    init(_ script: [CacheClearResult] = []) {
        self.script = Mutex(script)
        (stream, continuation) = AsyncStream.makeStream(of: Int.self)
    }

    var calls: Int {
        count.withLock { $0 }
    }

    func clear() -> CacheClearResult {
        let result = script.withLock { $0.isEmpty ? .cleared : $0.removeFirst() }
        let index = count.withLock { count -> Int in
            count += 1
            return count
        }
        continuation.yield(index)
        return result
    }
}

private final class LogSink: Sendable {
    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var all: [String] {
        lines.withLock { $0 }
    }
}

private struct Harness {
    let scheduler: CacheClearScheduler
    let fake: ScriptedClear
    let clock: ManualClock
    let logs: LogSink
}

final class CacheClearSchedulerTests: XCTestCase {
    private func make(_ script: [CacheClearResult] = []) -> Harness {
        let fake = ScriptedClear(script)
        let clock = ManualClock()
        let logs = LogSink()
        let scheduler = CacheClearScheduler(
            clock: clock, log: { logs.append($0) }, clear: { fake.clear() }
        )
        return Harness(scheduler: scheduler, fake: fake, clock: clock, logs: logs)
    }

    func testSuccessClearsOnce() async {
        let harness = make()
        let scheduler = harness.scheduler
        let fake = harness.fake
        scheduler.clearCache()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(fake.calls, 1)
    }

    func testIdleWithoutRequestsDoesNotClear() async {
        let harness = make()
        let scheduler = harness.scheduler
        let fake = harness.fake
        await scheduler.waitUntilIdle()
        XCTAssertEqual(fake.calls, 0)
    }

    func testThrottleThenSuccessRetriesWithBackoff() async {
        let harness = make([.throttled, .failed, .throttled])
        let scheduler = harness.scheduler
        let fake = harness.fake
        let clock = harness.clock
        var calls = fake.stream.makeAsyncIterator()
        scheduler.request()
        _ = await calls.next()
        for delay in [Duration.milliseconds(50), .milliseconds(100), .milliseconds(200)] {
            let before = fake.calls
            await clock.waitForSleepers(1)
            clock.advance(by: delay - .milliseconds(1))
            XCTAssertEqual(clock.sleeperCount, 1, "still backing off")
            XCTAssertEqual(fake.calls, before)
            clock.advance(by: .milliseconds(1))
            _ = await calls.next()
        }
        await scheduler.waitUntilIdle()
        XCTAssertEqual(fake.calls, 4)
    }

    func testBackoffIsCappedAtOneSecond() async {
        let harness = make(Array(repeating: .throttled, count: 7))
        let scheduler = harness.scheduler
        let fake = harness.fake
        let clock = harness.clock
        var calls = fake.stream.makeAsyncIterator()
        scheduler.request()
        _ = await calls.next()
        let delays: [Duration] = [
            .milliseconds(50), .milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800),
            .seconds(1), .seconds(1),
        ]
        for delay in delays {
            await clock.waitForSleepers(1)
            clock.advance(by: delay - .milliseconds(1))
            XCTAssertEqual(clock.sleeperCount, 1, "backoff before the retry is \(delay)")
            clock.advance(by: .milliseconds(1))
            _ = await calls.next()
        }
        await scheduler.waitUntilIdle()
        XCTAssertEqual(fake.calls, 8)
    }

    func testRapidRequestsCoalesce() async {
        let harness = make()
        let scheduler = harness.scheduler
        let fake = harness.fake
        for _ in 0 ..< 10 {
            scheduler.request()
        }
        await scheduler.waitUntilIdle()
        XCTAssertGreaterThanOrEqual(fake.calls, 1)
        XCTAssertLessThanOrEqual(fake.calls, 2)
    }

    func testRequestsDuringRetryCoalesceIntoOneMoreClear() async {
        let harness = make([.throttled])
        let scheduler = harness.scheduler
        let fake = harness.fake
        let clock = harness.clock
        var calls = fake.stream.makeAsyncIterator()
        scheduler.request()
        _ = await calls.next()
        await clock.waitForSleepers(1)
        for _ in 0 ..< 10 {
            scheduler.request()
        }
        clock.advance(by: .milliseconds(50))
        await scheduler.waitUntilIdle()
        // Throttled call, its successful retry, then exactly one clear for everything requested meanwhile.
        XCTAssertEqual(fake.calls, 3)
    }

    func testRequestDuringRetryIsNotLost() async {
        let harness = make([.throttled])
        let scheduler = harness.scheduler
        let fake = harness.fake
        let clock = harness.clock
        var calls = fake.stream.makeAsyncIterator()
        scheduler.request()
        _ = await calls.next()
        await clock.waitForSleepers(1)
        scheduler.request()
        clock.advance(by: .milliseconds(50))
        let retry = await calls.next()
        XCTAssertEqual(retry, 2)
        let again = await calls.next()
        XCTAssertEqual(again, 3, "the request that arrived during the retry clears again after it succeeded")
        await scheduler.waitUntilIdle()
        XCTAssertEqual(fake.calls, 3)
    }

    func testBackoffRestartsForTheNextRequest() async {
        let harness = make([.throttled, .cleared, .throttled])
        let scheduler = harness.scheduler
        let fake = harness.fake
        let clock = harness.clock
        var calls = fake.stream.makeAsyncIterator()
        scheduler.request()
        _ = await calls.next()
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(50))
        _ = await calls.next()
        await scheduler.waitUntilIdle()
        scheduler.request()
        _ = await calls.next()
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(50))
        _ = await calls.next()
        await scheduler.waitUntilIdle()
        XCTAssertEqual(fake.calls, 4)
    }

    func testPersistentFailureIsLoggedFirstThenRoughlyEveryThirtySeconds() async {
        let harness = make([.failed, .failed, .failed, .failed])
        let scheduler = harness.scheduler
        let fake = harness.fake
        let clock = harness.clock
        let logs = harness.logs
        func failureLines() -> Int {
            logs.all.filter { $0.contains("failed") }.count
        }
        var calls = fake.stream.makeAsyncIterator()
        scheduler.request()
        _ = await calls.next()
        await clock.waitForSleepers(1)
        XCTAssertEqual(failureLines(), 1, "the first failure is logged")
        clock.advance(by: .milliseconds(50))
        _ = await calls.next()
        await clock.waitForSleepers(1)
        XCTAssertEqual(failureLines(), 1, "a repeat within 30 s is not logged")
        clock.advance(by: .seconds(31))
        _ = await calls.next()
        await clock.waitForSleepers(1)
        XCTAssertEqual(failureLines(), 2, "a failure 30 s after the last line is logged again")
        clock.advance(by: .seconds(1))
        _ = await calls.next()
        await clock.waitForSleepers(1)
        XCTAssertEqual(failureLines(), 2)
        clock.advance(by: .seconds(1))
        await scheduler.waitUntilIdle()
        XCTAssertFalse(logs.all.contains { $0.contains("/") }, "no paths")
    }
}
