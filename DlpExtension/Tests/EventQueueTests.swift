import Foundation
import XCTest

final class EventQueueTests: XCTestCase {
    private func event(
        _ number: Int, path: String = "/bin/cat", file: String? = nil, decision: AccessDecision = .deny
    ) -> AccessEvent {
        AccessEvent(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID(),
            timestamp: Date(timeIntervalSince1970: Double(number)),
            process: ProcessIdentity(path: path, signingId: "", teamId: ""),
            responsible: nil,
            file: file ?? "/secret/\(number)",
            decision: decision,
            ruleId: nil
        )
    }

    private func ids(_ events: [AccessEvent]) -> [UUID] {
        events.map(\.id)
    }

    func testDrainReturnsOldestFirstAndRemoves() async {
        let queue = EventQueue()
        let events = (1 ... 3).map { event($0) }
        for item in events {
            await queue.record(item)
        }
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(ids(drained), ids(events))
        let count = await queue.count
        XCTAssertEqual(count, 0)
        let again = await queue.drain(max: 10)
        XCTAssertTrue(again.isEmpty)
    }

    func testDrainRespectsMax() async {
        let queue = EventQueue()
        let events = (1 ... 5).map { event($0) }
        for item in events {
            await queue.record(item)
        }
        let first = await queue.drain(max: 2)
        XCTAssertEqual(ids(first), ids(Array(events[0 ..< 2])))
        let remaining = await queue.count
        XCTAssertEqual(remaining, 3)
        let none = await queue.drain(max: 0)
        XCTAssertTrue(none.isEmpty)
        let rest = await queue.drain(max: 100)
        XCTAssertEqual(ids(rest), ids(Array(events[2...])))
    }

    func testDuplicateWithinWindowIsDropped() async {
        let clock = ManualClock()
        let queue = EventQueue(clock: clock)
        await queue.record(event(1, file: "/a"))
        clock.advance(by: .seconds(4))
        await queue.record(event(2, file: "/a"))
        let count = await queue.count
        XCTAssertEqual(count, 1)
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(ids(drained), ids([event(1, file: "/a")]))
    }

    func testDuplicateAfterWindowIsKept() async {
        let clock = ManualClock()
        let queue = EventQueue(clock: clock)
        await queue.record(event(1, file: "/a"))
        clock.advance(by: .seconds(6))
        await queue.record(event(2, file: "/a"))
        let count = await queue.count
        XCTAssertEqual(count, 2)
    }

    func testDifferentDecisionIsNotDuplicate() async {
        let queue = EventQueue(clock: ManualClock())
        await queue.record(event(1, file: "/a", decision: .deny))
        await queue.record(event(2, file: "/a", decision: .allow))
        let count = await queue.count
        XCTAssertEqual(count, 2)
    }

    func testDifferentProcessPathOrFileIsNotDuplicate() async {
        let queue = EventQueue(clock: ManualClock())
        await queue.record(event(1, path: "/bin/cat", file: "/a"))
        await queue.record(event(2, path: "/bin/ls", file: "/a"))
        await queue.record(event(3, path: "/bin/cat", file: "/b"))
        let count = await queue.count
        XCTAssertEqual(count, 3)
    }

    func testOverflowDropsOldest() async {
        let queue = EventQueue(capacity: 3, clock: ManualClock())
        let events = (1 ... 5).map { event($0) }
        for item in events {
            await queue.record(item)
        }
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(ids(drained), ids(Array(events[2...])))
    }

    func testTenThousandEventsStayBounded() async {
        let queue = EventQueue(clock: ManualClock())
        for number in 1 ... 10000 {
            await queue.record(event(number))
        }
        let count = await queue.count
        XCTAssertEqual(count, 1000)
        let drained = await queue.drain(max: 1)
        XCTAssertEqual(ids(drained), ids([event(9001)]))
    }

    func testDedupeTableIsPrunedBeyondTwiceTheCapacity() async {
        let queue = EventQueue(capacity: 3, clock: ManualClock())
        for number in 1 ... 7 {
            await queue.record(event(number))
        }
        // The 7th insert pushed the table past 2x capacity; all keys are inside the window, so only the
        // newest three survive. A repeat of a surviving key is a duplicate, a repeat of an evicted key is not.
        await queue.record(event(8, file: "/secret/7"))
        await queue.record(event(9, file: "/secret/1"))
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(ids(drained), ids([event(6), event(7), event(9, file: "/secret/1")]))
    }

    func testExpiredDedupeKeysAreForgottenOnPrune() async {
        let clock = ManualClock()
        let queue = EventQueue(capacity: 3, clock: clock)
        for number in 1 ... 3 {
            await queue.record(event(number))
        }
        clock.advance(by: .seconds(6))
        for number in 4 ... 7 {
            await queue.record(event(number))
        }
        // Keys 1-3 expired and were dropped by the prune; keys 4-7 are live but only the newest three are kept.
        await queue.record(event(8, file: "/secret/7"))
        await queue.record(event(9, file: "/secret/1"))
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(ids(drained), ids([event(6), event(7), event(9, file: "/secret/1")]))
    }

    func testUpdatesStreamYieldsRecordedEvents() async {
        let queue = EventQueue(clock: ManualClock())
        var iterator = queue.updates.makeAsyncIterator()
        await queue.record(event(1))
        await queue.record(event(2))
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first?.id, event(1).id)
        XCTAssertEqual(second?.id, event(2).id)
    }

    func testDuplicateDoesNotYield() async {
        let queue = EventQueue(clock: ManualClock())
        var iterator = queue.updates.makeAsyncIterator()
        await queue.record(event(1, file: "/a"))
        await queue.record(event(2, file: "/a"))
        await queue.record(event(3, file: "/b"))
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first?.id, event(1).id)
        XCTAssertEqual(second?.id, event(3).id)
    }

    func testRecordNeverBlocksWithoutConsumer() async {
        let queue = EventQueue(clock: ManualClock())
        for number in 1 ... 500 {
            await queue.record(event(number))
        }
        var iterator = queue.updates.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.id, event(401).id) // bufferingNewest(100) keeps the last 100
    }
}
