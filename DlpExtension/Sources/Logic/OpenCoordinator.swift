import CoreBridge
import Foundation
import Synchronization

/// Identifies a process instance (from its audit token); `pidVersion` distinguishes reused pids.
struct ProcessToken: Sendable, Hashable {
    let pid: Int32
    let pidVersion: Int32
    /// The raw `audit_token_t` words (8) when known: lets the resolver address exactly this process instance.
    let auditToken: [UInt32]?

    init(pid: Int32, pidVersion: Int32, auditToken: [UInt32]? = nil) {
        self.pid = pid
        self.pidVersion = pidVersion
        self.auditToken = auditToken
    }

    /// Reads pid and pid version from the `audit_token_t` words (`val[5]` and `val[7]`, as libbsm does).
    init?(auditTokenWords words: [UInt32]) {
        guard words.count == 8 else { return nil }
        self.init(pid: Int32(bitPattern: words[5]), pidVersion: Int32(bitPattern: words[7]), auditToken: words)
    }
}

/// Looks up the code-signing identity of a live process.
protocol ProcessResolving: Sendable {
    /// `nil` when the process is gone or cannot be inspected.
    func identity(of token: ProcessToken) async -> ProcessIdentity?
}

/// An `AUTH_OPEN` that the fast path could not answer.
struct OpenRequest: Sendable {
    let file: String
    let process: ProcessIdentity
    let responsible: ProcessToken?
    /// Time left until the Endpoint Security deadline when the event was received.
    let remaining: Duration
}

enum OpenResponse: Sendable, Equatable {
    case allow
    case deny
}

/// Forwards only the first response; Endpoint Security must be answered exactly once per message.
final class ResponseGate: Sendable {
    private let sent = Mutex(false)
    private let respond: @Sendable (OpenResponse) -> Void

    init(_ respond: @escaping @Sendable (OpenResponse) -> Void) {
        self.respond = respond
    }

    /// Returns true when this call was the one forwarded.
    @discardableResult
    func send(_ response: OpenResponse) -> Bool {
        let first = sent.withLock { sent -> Bool in
            defer { sent = true }
            return !sent
        }
        if first {
            respond(response)
        }
        return first
    }
}

/// Answers `AUTH_OPEN` events: inline for the fast path, otherwise by an evaluation task raced against a
/// watchdog that allows at half of the remaining deadline. Fail-open: no policy, unresolvable responsible
/// process, a missed watchdog or too many evaluations in flight all yield allow.
final class OpenCoordinator: Sendable {
    private let holder: PolicyHolder
    private let resolver: any ProcessResolving
    private let events: any EventRecording
    /// Fixes a deadline `offset` from now on the injected clock and returns a sleep until it.
    private let sleeper: @Sendable (Duration) -> @Sendable () async throws -> Void
    private let log: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    /// Evaluations may block on the resolver; beyond this many in flight candidates are allowed unevaluated so a
    /// burst cannot exhaust the cooperative pool and starve the watchdogs.
    private let maxInFlight: Int
    private let inFlight = Mutex(0)

    init(
        holder: PolicyHolder, resolver: any ProcessResolving, events: any EventRecording,
        clock: any Clock<Duration> = ContinuousClock(), maxInFlight: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init, log: @escaping @Sendable (String) -> Void
    ) {
        self.holder = holder
        self.resolver = resolver
        self.events = events
        sleeper = Self.deadlineSleeper(on: clock)
        self.maxInFlight = maxInFlight
        self.now = now
        self.log = log
    }

    /// Number of candidate evaluations started and not yet finished.
    var inFlightCount: Int {
        inFlight.withLock { $0 }
    }

    /// Lossy UTF-8 decoding: invalid bytes become U+FFFD instead of failing.
    static func decodePath(_ bytes: UnsafeRawBufferPointer) -> String {
        // Lossy on purpose: a file name with invalid UTF-8 must still be evaluated and logged, never dropped.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    /// Synchronous and allocation-free; safe to call from the Endpoint Security handler.
    func fastPathAllows(_ path: UnsafeRawBufferPointer) -> Bool {
        holder.fastPathAllows(path)
    }

    /// `fastPathAllows` plus the policy generation it was decided under. Synchronous and allocation-free; the
    /// adapter compares the generation with `policyGeneration` after caching an allow.
    func fastPathDecision(_ path: UnsafeRawBufferPointer) -> (allows: Bool, generation: UInt64) {
        holder.fastPathDecision(path)
    }

    /// Generation of the active policy; changes on every policy activation or reset.
    var policyGeneration: UInt64 {
        holder.generation
    }

    /// Never blocks: starts the evaluation and the watchdog and returns. `respond` is called exactly once — before
    /// returning when the evaluation cap is reached.
    func handleCandidate(_ request: OpenRequest, respond: @escaping @Sendable (OpenResponse) -> Void) {
        let arrivedAt = now()
        let admitted = inFlight.withLock { count -> Bool in
            guard count < maxInFlight else { return false }
            count += 1
            return true
        }
        guard admitted else {
            respond(.allow)
            log("evaluation cap of \(maxInFlight) in flight reached; allowed an open without evaluating it")
            return
        }
        let gate = ResponseGate(respond)
        // The deadline is fixed now, on the ES thread: scheduling delay of the task must not eat the margin.
        let sleepUntilDeadline = sleeper(request.remaining / 2)
        let watchdog = Task(priority: .high) { [log] in
            do {
                try await sleepUntilDeadline()
            } catch {
                return // cancelled: the verdict was sent first
            }
            if gate.send(.allow) {
                log("watchdog allowed an open after \(request.remaining / 2) without a verdict")
            }
        }
        Task {
            await evaluate(request, arrivedAt: arrivedAt, gate: gate, watchdog: watchdog)
        }
    }

    /// Frees the evaluation slot; called once per admitted candidate, before its verdict is sent.
    private func finishEvaluation() {
        inFlight.withLock { $0 -= 1 }
    }

    private func evaluate(
        _ request: OpenRequest, arrivedAt: Date, gate: ResponseGate, watchdog: Task<Void, Never>
    ) async {
        guard let engine = holder.engine() else {
            finishEvaluation()
            watchdog.cancel()
            gate.send(.allow)
            return
        }
        var responsible: ProcessIdentity?
        if let token = request.responsible {
            responsible = await resolver.identity(of: token)
        }
        let decision = engine.evaluate(
            WDAccessRequest(
                filePath: request.file, process: Self.info(request.process), responsible: responsible.map(Self.info)
            )
        )
        let verdict: OpenResponse = decision.deny ? .deny : .allow
        finishEvaluation()
        watchdog.cancel()
        let delivered = gate.send(verdict)
        if !delivered {
            log("late verdict \(verdict) discarded: the watchdog already allowed")
        }
        // The event records what Endpoint Security was told; a late deny keeps its rule id for the log.
        await events.record(
            AccessEvent(
                id: UUID(), timestamp: arrivedAt, process: request.process, responsible: responsible,
                file: request.file, decision: delivered && decision.deny ? .deny : .allow,
                ruleId: decision.deny ? decision.ruleId : nil
            )
        )
    }

    /// Opens the clock existential once; each call of the result reads `now` synchronously.
    private static func deadlineSleeper<C: Clock>(
        on clock: C
    ) -> @Sendable (Duration) -> @Sendable () async throws -> Void where C.Duration == Duration {
        { offset in
            let deadline = clock.now.advanced(by: offset)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    private static func info(_ identity: ProcessIdentity) -> WDProcessInfo {
        WDProcessInfo(path: identity.path, signingId: identity.signingId, teamId: identity.teamId)
    }
}
