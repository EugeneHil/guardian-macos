import CoreBridge
import Foundation
import Synchronization
import XCTest

private typealias Fixture = CoordinatorFixture

final class OpenCoordinatorTests: XCTestCase {
    private func make(
        withPolicy: Bool = true, resolver: FakeResolver = FakeResolver()
    ) throws -> OpenCoordinatorRig {
        try OpenCoordinatorRig.make(withPolicy: withPolicy, resolver: resolver)
    }

    private func fastPathAllows(_ coordinator: OpenCoordinator, _ path: String) -> Bool {
        var copy = path
        return copy.withUTF8 { coordinator.fastPathAllows(UnsafeRawBufferPointer($0)) }
    }

    // MARK: - Fast path

    func testFastPathAllowsUnprotected() throws {
        let rig = try make()
        XCTAssertTrue(fastPathAllows(rig.coordinator, "/usr/lib/libc.dylib"))
        XCTAssertFalse(fastPathAllows(rig.coordinator, Fixture.secretFile))
        let empty = try make(withPolicy: false)
        XCTAssertTrue(fastPathAllows(empty.coordinator, Fixture.secretFile))
    }

    // MARK: - Evaluation

    func testDeniedCandidateRecordsEventAndDenies() async throws {
        let rig = try make()
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.python)
        let response = await responses.next()
        XCTAssertEqual(response, .deny)
        let event = await events.next()
        XCTAssertEqual(event?.decision, .deny)
        XCTAssertEqual(event?.ruleId, "no-secrets")
        XCTAssertEqual(event?.file, Fixture.secretFile)
        XCTAssertEqual(event?.process, Fixture.python)
        XCTAssertNil(event?.responsible)
        XCTAssertEqual(rig.resolver.calls, 0)
        XCTAssertEqual(rig.responses.all, [.deny])
    }

    func testAllowedCandidateRecordsAllowEvent() async throws {
        let rig = try make()
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.cat)
        let response = await responses.next()
        XCTAssertEqual(response, .allow)
        let event = await events.next()
        XCTAssertEqual(event?.decision, .allow)
        XCTAssertNil(event?.ruleId)
        XCTAssertEqual(event?.process, Fixture.cat)
        XCTAssertEqual(rig.responses.all, [.allow])
    }

    func testResponsibleProcessIsResolvedAndMatched() async throws {
        let rig = try make(resolver: FakeResolver([Fixture.claudeToken: Fixture.claude]))
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken)
        let response = await responses.next()
        XCTAssertEqual(response, .deny)
        let event = await events.next()
        XCTAssertEqual(event?.decision, .deny)
        XCTAssertEqual(event?.ruleId, "no-secrets")
        XCTAssertEqual(event?.process, Fixture.node)
        XCTAssertEqual(event?.responsible, Fixture.claude)
        XCTAssertEqual(rig.resolver.calls, 1)
    }

    func testUnresolvableResponsibleDoesNotCrash() async throws {
        let rig = try make(resolver: FakeResolver([Fixture.claudeToken: Fixture.claude]))
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.unknownToken)
        let response = await responses.next()
        XCTAssertEqual(response, .allow)
        let event = await events.next()
        XCTAssertEqual(event?.decision, .allow)
        XCTAssertNil(event?.responsible)
        XCTAssertEqual(rig.resolver.calls, 1)
    }

    func testNoEngineAllows() async throws {
        let rig = try make(withPolicy: false, resolver: FakeResolver([Fixture.claudeToken: Fixture.claude]))
        var responses = rig.responses.stream.makeAsyncIterator()
        rig.handle(process: Fixture.python, responsible: Fixture.claudeToken)
        let response = await responses.next()
        XCTAssertEqual(response, .allow)
        XCTAssertEqual(rig.resolver.calls, 0)
        let recorded = await rig.queue.count
        XCTAssertEqual(recorded, 0)
    }

    // MARK: - Watchdog

    func testWatchdogAllowsOnce() async throws {
        let rig = try make(resolver: FakeResolver([Fixture.claudeToken: Fixture.cat], gated: true))
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        var log = rig.log.lines.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken, remaining: .milliseconds(100))
        await rig.clock.waitForSleepers(1)
        rig.clock.advance(by: .milliseconds(49))
        XCTAssertEqual(rig.clock.sleeperCount, 1, "the watchdog must not fire before 50 % of the remaining time")
        rig.clock.advance(by: .milliseconds(1))
        let response = await responses.next()
        XCTAssertEqual(response, .allow)
        let line = await log.next()
        XCTAssertTrue(line?.contains("watchdog") ?? false, String(describing: line))
        rig.resolver.release()
        let event = await events.next() // the evaluation finished and its (allow) verdict went through the gate
        XCTAssertEqual(event?.decision, .allow)
        XCTAssertEqual(rig.responses.all, [.allow])
    }

    func testLateVerdictIsDiscarded() async throws {
        let rig = try make(resolver: FakeResolver([Fixture.claudeToken: Fixture.claude], gated: true))
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        var log = rig.log.lines.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken, remaining: .milliseconds(100))
        rig.clock.advance(by: .milliseconds(50))
        let response = await responses.next()
        XCTAssertEqual(response, .allow)
        let watchdogLine = await log.next()
        XCTAssertTrue(watchdogLine?.contains("watchdog") ?? false, String(describing: watchdogLine))
        rig.resolver.release()
        let event = await events.next()
        XCTAssertEqual(event?.decision, .allow, "the event records what Endpoint Security was actually told")
        XCTAssertEqual(event?.ruleId, "no-secrets", "the rule that would have applied is kept")
        let lateLine = await log.next() // logged before the event is recorded
        XCTAssertTrue(lateLine?.contains("late") ?? false, String(describing: lateLine))
        XCTAssertEqual(rig.responses.all, [.allow])
    }

    func testVerdictWinningTheRaceRecordsDeny() async throws {
        let rig = try make(resolver: FakeResolver([Fixture.claudeToken: Fixture.claude], gated: true))
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken, remaining: .milliseconds(100))
        rig.clock.advance(by: .milliseconds(49))
        rig.resolver.release()
        let response = await responses.next()
        XCTAssertEqual(response, .deny)
        let event = await events.next()
        XCTAssertEqual(event?.decision, .deny)
        XCTAssertEqual(event?.ruleId, "no-secrets")
        XCTAssertEqual(rig.responses.all, [.deny])
    }

    func testWatchdogDeadlineIsFixedWhenTheEventArrives() async throws {
        let rig = try make(resolver: FakeResolver([Fixture.claudeToken: Fixture.cat], gated: true))
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken, remaining: .milliseconds(100))
        // No suspension point since `handle`: time passes before the watchdog task may even have started, as
        // under scheduling delay. The allow must still come at 50 % of the budget measured from arrival.
        rig.clock.advance(by: .milliseconds(50))
        let response = await responses.next()
        XCTAssertEqual(response, .allow)
        rig.resolver.release()
        _ = await events.next()
        XCTAssertEqual(rig.responses.all, [.allow])
    }

    func testZeroRemainingAllowsImmediatelyOnce() async throws {
        try await assertImmediateSingleAllow(remaining: .zero)
    }

    func testNegativeRemainingAllowsImmediatelyOnce() async throws {
        try await assertImmediateSingleAllow(remaining: .milliseconds(-10))
    }

    private func assertImmediateSingleAllow(remaining: Duration) async throws {
        let rig = try make(resolver: FakeResolver([Fixture.claudeToken: Fixture.claude], gated: true))
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken, remaining: remaining)
        let response = await responses.next() // the clock never moves
        XCTAssertEqual(response, .allow)
        rig.resolver.release()
        let event = await events.next()
        XCTAssertEqual(event?.decision, .allow)
        XCTAssertEqual(rig.responses.all, [.allow])
    }

    func testVerdictCancelsWatchdog() async throws {
        let rig = try make(resolver: FakeResolver([Fixture.claudeToken: Fixture.claude], gated: true))
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.node, responsible: Fixture.claudeToken, remaining: .milliseconds(100))
        await rig.clock.waitForSleepers(1)
        rig.resolver.release()
        let response = await responses.next()
        XCTAssertEqual(response, .deny)
        XCTAssertEqual(rig.clock.sleeperCount, 0, "the watchdog sleep is cancelled by the verdict")
        _ = await events.next()
        rig.clock.advance(by: .seconds(1))
        XCTAssertEqual(rig.responses.all, [.deny])
    }

    func testResponseGateSendsOnlyOnce() async {
        let calls = Mutex<[OpenResponse]>([])
        let gate = ResponseGate { response in calls.withLock { $0.append(response) } }
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 100 {
                group.addTask { gate.send(index.isMultiple(of: 2) ? .allow : .deny) }
            }
        }
        XCTAssertEqual(calls.withLock { $0.count }, 1)
    }

    // MARK: - Path forms

    func testInvalidUtf8PathDoesNotCrash() async throws {
        let bytes: [UInt8] = [0x2F, 0xFF, 0x2E, 0x65, 0x6E, 0x76]
        let decoded = bytes.withUnsafeBytes { OpenCoordinator.decodePath($0) }
        XCTAssertTrue(decoded.unicodeScalars.contains("\u{FFFD}"))
        let rig = try make()
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(file: decoded, process: Fixture.python)
        let response = await responses.next()
        XCTAssertEqual(response, .allow)
        let event = await events.next()
        XCTAssertEqual(event?.file, decoded)
    }

    func testVeryLongPathIsHandled() async throws {
        let suffix = "/.secrets"
        let path = "/" + String(repeating: "a", count: 4096 - 1 - suffix.utf8.count) + suffix
        XCTAssertEqual(path.utf8.count, 4096)
        let rig = try make()
        XCTAssertFalse(fastPathAllows(rig.coordinator, path))
        let decoded = Array(path.utf8).withUnsafeBytes { OpenCoordinator.decodePath($0) }
        XCTAssertEqual(decoded, path)
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(file: decoded, process: Fixture.python)
        let response = await responses.next()
        XCTAssertEqual(response, .deny)
        let event = await events.next()
        XCTAssertEqual(event?.file, path)
    }

    // MARK: - Fast path generation

    func testFastPathDecisionCarriesThePolicyGeneration() throws {
        let holder = PolicyHolder()
        let coordinator = OpenCoordinator(
            holder: holder, resolver: FakeResolver(), events: EventQueue(clock: ManualClock()), log: { _ in }
        )
        var path = Fixture.secretFile
        let before = path.withUTF8 { coordinator.fastPathDecision(UnsafeRawBufferPointer($0)) }
        XCTAssertTrue(before.allows)
        XCTAssertEqual(before.generation, holder.generation)
        XCTAssertEqual(coordinator.policyGeneration, holder.generation)

        try holder.set(policy: GDPolicy(json: Data(Fixture.policy.utf8)))
        XCTAssertNotEqual(coordinator.policyGeneration, before.generation)
        let after = path.withUTF8 { coordinator.fastPathDecision(UnsafeRawBufferPointer($0)) }
        XCTAssertFalse(after.allows)
        XCTAssertEqual(after.generation, coordinator.policyGeneration)
    }
}
