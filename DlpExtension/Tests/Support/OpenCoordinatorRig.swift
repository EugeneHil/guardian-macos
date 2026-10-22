import CoreBridge
import Foundation
import Synchronization

/// One-shot async latch: `wait()` suspends until `open()` has been called (before or after).
final class Latch: Sendable {
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
final class FakeResolver: ProcessResolving {
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
final class Responses: Sendable {
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

/// Streams every log line to the test.
final class CoordinatorLog: Sendable {
    private let continuation: AsyncStream<String>.Continuation
    let lines: AsyncStream<String>

    init() {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
    }

    func add(_ line: String) {
        continuation.yield(line)
    }
}

enum CoordinatorFixture {
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

/// A coordinator wired to fakes: a manual watchdog clock, an event queue and a collecting `respond`.
struct OpenCoordinatorRig {
    let coordinator: OpenCoordinator
    let clock: ManualClock
    let queue: EventQueue
    let resolver: FakeResolver
    let responses: Responses
    let log: CoordinatorLog

    static func make(
        withPolicy: Bool = true, resolver: FakeResolver = FakeResolver(), maxInFlight: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> Self {
        let holder = PolicyHolder()
        if withPolicy {
            try holder.set(policy: WDPolicy(json: Data(CoordinatorFixture.policy.utf8)))
        }
        let clock = ManualClock()
        let queue = EventQueue(clock: ManualClock())
        let log = CoordinatorLog()
        let coordinator = OpenCoordinator(
            holder: holder, resolver: resolver, events: queue, clock: clock, maxInFlight: maxInFlight, now: now,
            log: { log.add($0) }
        )
        return Self(
            coordinator: coordinator, clock: clock, queue: queue, resolver: resolver, responses: Responses(), log: log
        )
    }

    func handle(
        file: String = CoordinatorFixture.secretFile, process: ProcessIdentity, responsible: ProcessToken? = nil,
        remaining: Duration = .milliseconds(100)
    ) {
        let request = OpenRequest(file: file, process: process, responsible: responsible, remaining: remaining)
        coordinator.handleCandidate(request) { [responses] in responses.respond($0) }
    }
}
