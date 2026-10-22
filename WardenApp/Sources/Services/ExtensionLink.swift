import Foundation
import Synchronization

/// One connection to the extension's Mach service.
protocol XPCSession: Sendable {
    /// A proxy for one call; connection-level failures are reported to `onError` instead of the reply, and the call
    /// then returns at once (throwing or with a placeholder value that the caller ignores).
    func service(onError: @escaping @Sendable (any Error) -> Void) -> any WardenExtensionXPC
    /// Yields on interruption or invalidation of the connection; finishes once it is invalidated.
    func interruptions() -> AsyncStream<Void>
    func invalidate()
}

/// Opens connections; `client` is exported to the extension for live event callbacks.
protocol XPCConnectionProviding: Sendable {
    func connect(exporting client: any WardenClientXPC) throws -> any XPCSession
}

/// XPC client of the system extension. Every call is bounded by `callTimeout`; a call that times out or fails at
/// the XPC level throws `ExtensionLinkError.unavailable` and drops the connection, and the next call reconnects and
/// re-sends `subscribe`. An interruption between calls drops the connection the same way.
actor ExtensionLink: ExtensionLinking {
    private let provider: any XPCConnectionProviding
    private let clock: any Clock<Duration>
    private let callTimeout: Duration
    private let sink = LiveEventSink()
    private var current: (id: Int, session: any XPCSession)?
    private var lastSessionID = 0
    private var watcher: Task<Void, Never>?

    init(provider: any XPCConnectionProviding, clock: any Clock<Duration>, callTimeout: Duration = .seconds(5)) {
        self.provider = provider
        self.clock = clock
        self.callTimeout = callTimeout
    }

    func apply(policy: Data) async throws -> Int64 {
        try await call { try await $0.apply(policyData: policy) }
    }

    /// 0 means the extension has no policy yet (also while it is still loading its cached one).
    func currentPolicyVersion() async throws -> Int64 {
        try await call { await $0.currentPolicyVersion() }
    }

    /// The extension removes events from its queue before replying, so a late reply after a timeout, cancellation or
    /// decode failure loses up to 500 events: at-least-once delivery is not guaranteed (peek/ack drain is future work).
    func drainEvents(max: Int) async throws -> [AccessEvent] {
        let data = try await call { await $0.drainEvents(max: max) }
        do {
            return try XPCCoding.decodeList(data)
        } catch {
            throw ExtensionLinkError.unavailable
        }
    }

    /// Live events while a connection is up. Best-effort: events recorded while the app is not subscribed, or dropped
    /// by the extension for a slow client, are only available through `drainEvents`, and live events may duplicate
    /// drained ones (consumers that merge both dedupe by `AccessEvent.id`; the uploader uses `drainEvents` only).
    /// Each stream lives for the app's lifetime (across reconnects) until its consumer stops iterating.
    nonisolated func liveEvents() -> AsyncStream<AccessEvent> {
        sink.stream()
    }

    static func map(_ error: any Error) -> ExtensionLinkError {
        if let error = error as? ExtensionLinkError {
            return error
        }
        let nsError = error as NSError
        if nsError.domain == WardenXPCError.domain, nsError.code == WardenXPCError.invalidPolicyCode {
            return .invalidPolicy(nsError.userInfo[WardenXPCError.validationErrorsKey] as? [String] ?? [])
        }
        return .unavailable
    }

    private typealias XPCCall<T> = @Sendable (any WardenExtensionXPC) async throws -> T

    private func call<T: Sendable>(_ body: @escaping XPCCall<T>) async throws -> T {
        let (id, session) = try await connectedSession()
        do {
            return try await timed(session, cancellable: true, body)
        } catch is CancellationError {
            throw CancellationError() // the caller gave up; the connection itself is fine
        } catch {
            let mapped = Self.map(error)
            if mapped == .unavailable {
                drop(id)
            }
            throw mapped
        }
    }

    private func connectedSession() async throws -> (Int, any XPCSession) {
        if let current {
            return (current.id, current.session)
        }
        let session: any XPCSession
        do {
            session = try provider.connect(exporting: sink)
        } catch {
            throw ExtensionLinkError.unavailable
        }
        lastSessionID += 1
        let id = lastSessionID
        current = (id, session)
        let interruptions = session.interruptions()
        watcher = Task { [weak self] in
            for await _ in interruptions {
                await self?.drop(id)
                return
            }
        }
        let client = sink
        do {
            // Not cancellable: a subscription cut short would leave the connection without live events.
            try await timed(session, cancellable: false) { await $0.subscribe(client: client) }
        } catch {
            drop(id)
            throw ExtensionLinkError.unavailable
        }
        return (id, session)
    }

    /// Forgets and invalidates the connection `id` if it is still the current one.
    private func drop(_ id: Int) {
        guard let current, current.id == id else { return }
        self.current = nil
        watcher?.cancel()
        watcher = nil
        current.session.invalidate()
    }

    /// Resolves with whichever comes first: the reply, a connection error from the proxy's error handler (NSXPC then
    /// never calls the reply), `unavailable` after `callTimeout`, or `CancellationError` when the caller is cancelled.
    /// It never waits for the reply after that (an XPC reply ignores cancellation): a late reply hits the spent gate
    /// and is ignored. The `body` Task itself ends too: the session's service resumes a call whose reply NSXPC drops
    /// after a connection error (`ReplyBridge`); after a timeout the link drops and invalidates the session, so the
    /// connection's error handler ends the pending call promptly instead of waiting for a reply.
    private nonisolated func timed<T: Sendable>(
        _ session: any XPCSession, cancellable: Bool, _ body: @escaping XPCCall<T>
    ) async throws -> T {
        let clock = clock
        let timeout = callTimeout
        let gate = ResumeGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.arm(continuation) else { return } // cancelled before the call was sent
                gate.setTimer(Task {
                    do {
                        try await clock.sleep(for: timeout)
                    } catch {
                        return
                    }
                    gate.resume(with: .failure(ExtensionLinkError.unavailable))
                })
                let service = session.service(onError: { gate.resume(with: .failure($0)) })
                Task {
                    let result: Result<T, any Error>
                    do {
                        result = try await .success(body(service))
                    } catch {
                        result = .failure(error)
                    }
                    gate.resume(with: result)
                }
            }
        } onCancel: {
            if cancellable {
                gate.resume(with: .failure(CancellationError()))
            }
        }
    }
}

/// Resumes a continuation at most once; later results are ignored. A result that arrives before the continuation is
/// armed (an immediate cancellation) is kept and delivered on `arm`. Resolving cancels the timer first, so no sleeper
/// outlives the call.
final class ResumeGate<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var early: Result<T, any Error>?
        var timer: Task<Void, Never>?
        var resolved = false
    }

    private let state = Mutex(State())

    /// Returns false when the gate was already resolved (the continuation is then resumed at once).
    func arm(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        let early = state.withLock { state -> Result<T, any Error>? in
            if let early = state.early {
                state.early = nil
                return early
            }
            state.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
            return false
        }
        return true
    }

    func setTimer(_ timer: Task<Void, Never>) {
        let resolved = state.withLock { state -> Bool in
            if !state.resolved {
                state.timer = timer
            }
            return state.resolved
        }
        if resolved {
            timer.cancel()
        }
    }

    func resume(with result: Result<T, any Error>) {
        let (continuation, timer) = state.withLock { state -> (
            CheckedContinuation<T, any Error>?,
            Task<Void, Never>?
        ) in
            guard !state.resolved else { return (nil, nil) }
            state.resolved = true
            defer {
                state.continuation = nil
                state.timer = nil
            }
            if state.continuation == nil {
                state.early = result
            }
            return (state.continuation, state.timer)
        }
        timer?.cancel()
        continuation?.resume(with: result)
    }
}

/// The app's `WardenClientXPC` object. `eventRecorded` runs on an XPC queue: it only decodes and yields, never blocks.
final class LiveEventSink: NSObject, WardenClientXPC, Sendable {
    private struct State {
        var lastID = 0
        var continuations: [Int: AsyncStream<AccessEvent>.Continuation] = [:]
    }

    private let state = Mutex(State())

    func stream() -> AsyncStream<AccessEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AccessEvent.self, bufferingPolicy: .bufferingNewest(256)
        )
        let id = state.withLock { state -> Int in
            state.lastID += 1
            state.continuations[state.lastID] = continuation
            return state.lastID
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func eventRecorded(_ eventData: Data) {
        guard let event = try? XPCCoding.decode(eventData) else { return }
        let targets = state.withLock { Array($0.continuations.values) }
        for continuation in targets {
            continuation.yield(event)
        }
    }
}
