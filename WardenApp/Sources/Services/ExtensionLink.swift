import Foundation
import Synchronization

/// One connection to the extension's Mach service.
protocol XPCSession: Sendable {
    var service: any WardenExtensionXPC { get }
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
        let (id, service) = try await connectedService()
        do {
            return try await timed(service, body)
        } catch {
            let mapped = Self.map(error)
            if mapped == .unavailable {
                drop(id)
            }
            throw mapped
        }
    }

    private func connectedService() async throws -> (Int, any WardenExtensionXPC) {
        if let current {
            return (current.id, current.session.service)
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
            try await timed(session.service) { await $0.subscribe(client: client) }
        } catch {
            drop(id)
            throw ExtensionLinkError.unavailable
        }
        return (id, session.service)
    }

    /// Forgets and invalidates the connection `id` if it is still the current one.
    private func drop(_ id: Int) {
        guard let current, current.id == id else { return }
        self.current = nil
        watcher?.cancel()
        watcher = nil
        current.session.invalidate()
    }

    /// Resolves with the reply or with `unavailable` after `callTimeout`, whichever comes first. It does not wait for
    /// the reply after a timeout (an XPC reply ignores cancellation): the caller drops the connection, which makes the
    /// pending reply fail, and a late reply hits the already-used gate and is ignored.
    private nonisolated func timed<T: Sendable>(
        _ service: any WardenExtensionXPC, _ body: @escaping XPCCall<T>
    ) async throws -> T {
        let clock = clock
        let timeout = callTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate(continuation)
            let timer = Task {
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                gate.resume(with: .failure(ExtensionLinkError.unavailable))
            }
            Task {
                let result: Result<T, any Error>
                do {
                    result = try await .success(body(service))
                } catch {
                    result = .failure(error)
                }
                timer.cancel()
                gate.resume(with: result)
            }
        }
    }
}

/// Resumes a continuation at most once; later results are ignored.
private final class ResumeGate<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        let pending = continuation.withLock { stored -> CheckedContinuation<T, any Error>? in
            defer { stored = nil }
            return stored
        }
        pending?.resume(with: result)
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
