import CoreBridge
import Foundation
import Synchronization
import XCTest

/// One-shot async latch: `wait()` suspends until `open()` has been called (before or after).
private final class Latch: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.isOpen {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Resolves from a fixed table; when gated, every lookup suspends until `release()`.
private final class FakeResolver: ProcessResolving {
    private let identities: [ProcessToken: ProcessIdentity]
    private let gate: Latch?
    private let callCount = Mutex(0)

    init(_ identities: [ProcessToken: ProcessIdentity] = [:], gated: Bool = false) {
        self.identities = identities
        gate = gated ? Latch() : nil
    }

    var calls: Int {
        callCount.withLock { $0 }
    }

    func identity(of token: ProcessToken) async -> ProcessIdentity? {
        callCount.withLock { $0 += 1 }
        if let gate {
            await gate.wait()
        }
        return identities[token]
    }

    func release() {
        gate?.open()
    }
}

/// Collects every `respond` call and streams them to the test.
private final class Responses: Sendable {
    private let values = Mutex<[OpenResponse]>([])
    private let continuation: AsyncStream<OpenResponse>.Continuation
    let stream: AsyncStream<OpenResponse>

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: OpenResponse.self)
    }

    var all: [OpenResponse] {
        values.withLock { $0 }
    }

    func respond(_ response: OpenResponse) {
        values.withLock { $0.append(response) }
        continuation.yield(response)
    }
}

private final class LogBox: Sendable {
    private let continuation: AsyncStream<String>.Continuation
    let lines: AsyncStream<String>

    init() {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
    }

    func add(_ line: String) {
        continuation.yield(line)
    }
}

private enum Fixture {
    static let policy = """
    {"schemaVersion":1,"version":3,"rules":[{"id":"no-secrets","description":"d","targets":["**/.secrets"],\
    "action":"deny","processes":[{"signingIdPrefix":"com.anthropic.claude"},{"path":"/usr/bin/python3"}]}]}
    """
    static let secretFile = "/Users/a/p/.secrets"
    static let python = ProcessIdentity(path: "/usr/bin/python3", signingId: "", teamId: "")
    static let cat = ProcessIdentity(path: "/bin/cat", signingId: "com.apple.cat", teamId: "")
    static let node = ProcessIdentity(path: "/usr/local/bin/node", signingId: "", teamId: "")
    static let claude = ProcessIdentity(
        path: "/Applications/Claude.app/Contents/MacOS/Claude", signingId: "com.anthropic.claudefordesktop",
        teamId: "Q6L2SF6YDW"
    )
    static let claudeToken = ProcessToken(pid: 42, pidVersion: 7)
    static let unknownToken = ProcessToken(pid: 43, pidVersion: 1)
}

final class OpenCoordinatorTests: XCTestCase {
    private struct Rig {
        let coordinator: OpenCoordinator
        let clock: ManualClock
        let queue: EventQueue
        let resolver: FakeResolver
        let responses: Responses
        let log: LogBox

        func handle(
            file: String = Fixture.secretFile, process: ProcessIdentity, responsible: ProcessToken? = nil,
            remaining: Duration = .milliseconds(100)
        ) {
            let request = OpenRequest(file: file, process: process, responsible: responsible, remaining: remaining)
            coordinator.handleCandidate(request) { [responses] in responses.respond($0) }
        }
    }

    private func make(withPolicy: Bool = true, resolver: FakeResolver = FakeResolver()) throws -> Rig {
        let holder = PolicyHolder()
        if withPolicy {
            try holder.set(policy: WDPolicy(json: Data(Fixture.policy.utf8)))
        }
        let clock = ManualClock()
        let queue = EventQueue(clock: ManualClock())
        let log = LogBox()
        let coordinator = OpenCoordinator(
            holder: holder, resolver: resolver, events: queue, clock: clock, log: { log.add($0) }
        )
        return Rig(
            coordinator: coordinator, clock: clock, queue: queue, resolver: resolver, responses: Responses(), log: log
        )
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
}
