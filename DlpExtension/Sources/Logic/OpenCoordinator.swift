import CoreBridge
import Foundation
import Synchronization

/// Identifies a process instance (from its audit token); `pidVersion` distinguishes reused pids.
struct ProcessToken: Sendable, Hashable {
    let pid: Int32
    let pidVersion: Int32
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
/// process or a missed watchdog all yield allow.
final class OpenCoordinator: Sendable {
    private let holder: PolicyHolder
    private let resolver: any ProcessResolving
    private let events: any EventRecording
    private let clock: any Clock<Duration>
    private let log: @Sendable (String) -> Void

    init(
        holder: PolicyHolder, resolver: any ProcessResolving, events: any EventRecording,
        clock: any Clock<Duration> = ContinuousClock(), log: @escaping @Sendable (String) -> Void
    ) {
        self.holder = holder
        self.resolver = resolver
        self.events = events
        self.clock = clock
        self.log = log
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

    /// Never blocks: starts the evaluation and the watchdog and returns. `respond` is called exactly once.
    func handleCandidate(_ request: OpenRequest, respond: @escaping @Sendable (OpenResponse) -> Void) {
        let gate = ResponseGate(respond)
        let watchdog = Task { [clock, log] in
            do {
                try await clock.sleep(for: request.remaining / 2)
            } catch {
                return // cancelled: the verdict was sent first
            }
            if gate.send(.allow) {
                log("watchdog allowed an open after \(request.remaining / 2) without a verdict")
            }
        }
        Task {
            await evaluate(request, gate: gate, watchdog: watchdog)
        }
    }

    private func evaluate(_ request: OpenRequest, gate: ResponseGate, watchdog: Task<Void, Never>) async {
        guard let engine = holder.engine() else {
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
        watchdog.cancel()
        if !gate.send(verdict) {
            log("late verdict \(verdict) discarded: the watchdog already allowed")
        }
        await events.record(
            AccessEvent(
                id: UUID(), timestamp: Date(), process: request.process, responsible: responsible, file: request.file,
                decision: decision.deny ? .deny : .allow, ruleId: decision.deny ? decision.ruleId : nil
            )
        )
    }

    private static func info(_ identity: ProcessIdentity) -> WDProcessInfo {
        WDProcessInfo(path: identity.path, signingId: identity.signingId, teamId: identity.teamId)
    }
}
