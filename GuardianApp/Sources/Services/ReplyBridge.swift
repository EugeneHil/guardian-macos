import Foundation
import Synchronization

/// App-side mirror of `GuardianExtensionXPC` with reply blocks instead of `async`: the same selectors and argument
/// types, so the bytes on the wire are identical (`ReplyBridgeTests` compares both protocols through the Objective-C
/// runtime). The app uses it as the connection's remote interface because NSXPC never calls the reply of a message
/// that failed at the connection level: an `async`-imported call would then stay suspended forever, while a reply
/// block can be abandoned once the proxy's error handler has resolved the call.
@objc protocol GuardianExtensionReplyXPC: Sendable {
    @objc(applyWithPolicyData:completionHandler:)
    func apply(policyData: Data, reply: @escaping @Sendable (Int64, (any Error)?) -> Void)

    @objc(currentPolicyVersionWithCompletionHandler:)
    func currentPolicyVersion(reply: @escaping @Sendable (Int64) -> Void)

    @objc(drainEventsWithMax:completionHandler:)
    func drainEvents(max: Int, reply: @escaping @Sendable (Data) -> Void)

    @objc(subscribeWithClient:completionHandler:)
    func subscribe(client: GuardianClientXPC, reply: @escaping @Sendable () -> Void)
}

struct XPCProxyUnavailable: Error {}

enum ReplyBridge {
    /// Wraps one raw reply-block proxy into the `async` protocol `ExtensionLink` calls. `makeProxy` receives the
    /// error handler to install on the proxy (`remoteObjectProxyWithErrorHandler`): a connection error is reported to
    /// `onError` and then resumes every call still waiting on that proxy, so no call stays suspended.
    static func service(
        onError: @escaping @Sendable (any Error) -> Void,
        makeProxy: (@escaping @Sendable (any Error) -> Void) -> Any
    ) -> any GuardianExtensionXPC {
        let pending = PendingReplies()
        let proxy = makeProxy { error in
            onError(error)
            pending.fail(error)
        }
        guard let raw = proxy as? any GuardianExtensionReplyXPC else {
            return UnavailableService(onError: onError)
        }
        return ReplyBridgedService(raw: raw, pending: pending)
    }
}

/// `async` facade over a raw reply-block proxy. The non-throwing methods return a placeholder after a connection
/// error: `ExtensionLink` has resolved the call through `onError` by then and ignores the value.
private final class ReplyBridgedService: NSObject, GuardianExtensionXPC, Sendable {
    private let raw: any GuardianExtensionReplyXPC
    private let pending: PendingReplies

    init(raw: any GuardianExtensionReplyXPC, pending: PendingReplies) {
        self.raw = raw
        self.pending = pending
    }

    func apply(policyData: Data) async throws -> Int64 {
        let raw = raw
        return try await pending.call { reply in
            raw.apply(policyData: policyData) { version, error in
                reply(error.map { .failure($0) } ?? .success(version))
            }
        }
    }

    func currentPolicyVersion() async -> Int64 {
        let raw = raw
        return await (try? pending.call { reply in raw.currentPolicyVersion { reply(.success($0)) } }) ?? 0
    }

    func drainEvents(max: Int) async -> Data {
        let raw = raw
        return await (try? pending.call { reply in raw.drainEvents(max: max) { reply(.success($0)) } }) ?? Data()
    }

    func subscribe(client: any GuardianClientXPC) async {
        let raw = raw
        _ = try? await pending.call { reply in raw.subscribe(client: client) { reply(.success(())) } }
    }
}

/// Calls waiting for a reply on one proxy. Each resolves once, with its reply or the proxy's connection error,
/// whichever comes first; after an error, new calls fail without being sent.
private final class PendingReplies: Sendable {
    private struct State {
        var failure: (any Error)?
        var lastID = 0
        var waiting: [Int: @Sendable (any Error) -> Void] = [:]
    }

    private let state = Mutex(State())

    func call<T: Sendable>(
        _ send: (@escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let gate = ResumeGate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            guard gate.arm(continuation), let id = register({ gate.resume(with: .failure($0)) }) else { return }
            send { [weak self] result in
                self?.unregister(id)
                gate.resume(with: result)
            }
        }
    }

    /// Resumes every waiting call with `error` and fails the calls that follow.
    func fail(_ error: any Error) {
        let waiting = state.withLock { state -> [@Sendable (any Error) -> Void] in
            if state.failure == nil {
                state.failure = error
            }
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for onFailure in waiting {
            onFailure(error)
        }
    }

    /// Returns nil (after failing `onFailure` at once) when the proxy has already failed.
    private func register(_ onFailure: @escaping @Sendable (any Error) -> Void) -> Int? {
        let (id, failure) = state.withLock { state -> (Int?, (any Error)?) in
            if let failure = state.failure {
                return (nil, failure)
            }
            state.lastID += 1
            state.waiting[state.lastID] = onFailure
            return (state.lastID, nil)
        }
        if let failure {
            onFailure(failure)
        }
        return id
    }

    private func unregister(_ id: Int) {
        state.withLock { _ = $0.waiting.removeValue(forKey: id) }
    }
}

/// Stand-in when `NSXPCConnection` hands out a proxy of an unexpected type: every call reports `onError` at once
/// (the gate is resolved by then, so the values returned afterwards are ignored).
private final class UnavailableService: NSObject, GuardianExtensionXPC, Sendable {
    private let onError: @Sendable (any Error) -> Void

    init(onError: @escaping @Sendable (any Error) -> Void) {
        self.onError = onError
    }

    func apply(policyData _: Data) async throws -> Int64 {
        onError(XPCProxyUnavailable())
        throw XPCProxyUnavailable()
    }

    func currentPolicyVersion() async -> Int64 {
        onError(XPCProxyUnavailable())
        return 0
    }

    func drainEvents(max _: Int) async -> Data {
        onError(XPCProxyUnavailable())
        return Data()
    }

    func subscribe(client _: any GuardianClientXPC) async {
        onError(XPCProxyUnavailable())
    }
}
