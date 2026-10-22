import CoreBridge
import Foundation
import Synchronization
import XCTest

private typealias Fixture = CoordinatorFixture

/// The in-flight evaluation cap and the event timestamp of `OpenCoordinator`.
final class OpenCoordinatorCapTests: XCTestCase {
    // MARK: - Evaluation cap

    func testOverCapAllowsSynchronouslyWithoutEvaluating() async throws {
        let rig = try OpenCoordinatorRig.make(
            resolver: FakeResolver([Fixture.claudeToken: Fixture.claude], gated: true),
            maxInFlight: 1
        )
        var events = rig.queue.updates.makeAsyncIterator()
        var log = rig.log.lines.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken)
        XCTAssertEqual(rig.responses.all, [], "the first candidate is being evaluated")
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken)
        XCTAssertEqual(rig.responses.all, [.allow], "over the cap the open is allowed before handleCandidate returns")
        let line = await log.next()
        XCTAssertTrue(line?.contains("cap") ?? false, String(describing: line))
        XCTAssertFalse(line?.contains(Fixture.secretFile) ?? true, "no file paths in the log")
        rig.resolver.release()
        let event = await events.next()
        XCTAssertEqual(event?.decision, .deny)
        XCTAssertEqual(rig.resolver.calls, 1, "the over-cap candidate never reached the resolver")
        let recorded = await rig.queue.count
        XCTAssertEqual(recorded, 1, "no event is recorded for the unevaluated allow")
        XCTAssertEqual(rig.responses.all, [.allow, .deny])
    }

    func testCapBoundaryAndCounterReturnsToZero() async throws {
        let rig = try OpenCoordinatorRig.make(
            resolver: FakeResolver([Fixture.claudeToken: Fixture.claude], gated: true),
            maxInFlight: 2
        )
        var responses = rig.responses.stream.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken)
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken)
        XCTAssertEqual(rig.responses.all, [], "exactly maxInFlight candidates are evaluated")
        XCTAssertEqual(rig.coordinator.inFlightCount, 2)
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken)
        XCTAssertEqual(rig.responses.all, [.allow], "maxInFlight + 1 is allowed without evaluation")
        XCTAssertEqual(rig.coordinator.inFlightCount, 2)
        rig.resolver.release()
        // The events are deduplicated by the queue, so wait on the verdicts: each slot is freed before its verdict.
        var collected: [OpenResponse?] = []
        for _ in 0 ..< 3 {
            await collected.append(responses.next())
        }
        XCTAssertEqual(collected, [.allow, .deny, .deny])
        XCTAssertEqual(rig.resolver.calls, 2)
        XCTAssertEqual(rig.coordinator.inFlightCount, 0)
        // Both evaluations finished, so the cap is free again for the next two candidates.
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken)
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken)
        let fourth = await responses.next()
        let fifth = await responses.next()
        XCTAssertEqual([fourth, fifth], [.deny, .deny])
        XCTAssertEqual(rig.resolver.calls, 4)
        XCTAssertEqual(rig.coordinator.inFlightCount, 0)
    }

    func testCapIsReleasedWhenThereIsNoEngine() async throws {
        let rig = try OpenCoordinatorRig.make(withPolicy: false, maxInFlight: 1)
        var responses = rig.responses.stream.makeAsyncIterator()
        rig.handle(process: Fixture.python)
        let first = await responses.next()
        XCTAssertEqual(first, .allow)
        var log = rig.log.lines.makeAsyncIterator()
        XCTAssertEqual(rig.coordinator.inFlightCount, 0, "the slot is released before the verdict is sent")
        rig.handle(process: Fixture.python)
        _ = await responses.next()
        rig.log.add("end")
        let line = await log.next()
        XCTAssertEqual(line, "end", "the second candidate was not rejected by the cap")
    }

    // MARK: - Timestamp

    func testEventTimestampIsTakenWhenTheEventArrives() async throws {
        let arrival = Date(timeIntervalSince1970: 1000)
        let current = Mutex(arrival)
        let rig = try OpenCoordinatorRig.make(
            resolver: FakeResolver([Fixture.claudeToken: Fixture.claude], gated: true),
            now: { current.withLock { $0 } }
        )
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken)
        current.withLock { $0 = Date(timeIntervalSince1970: 2000) }
        rig.resolver.release()
        let event = await events.next()
        XCTAssertEqual(event?.timestamp, arrival)
    }
}
