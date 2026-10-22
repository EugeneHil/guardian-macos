import Foundation
import Synchronization

final class FakeExtensionLink: ExtensionLinking, Sendable {
    private struct State {
        var applyScript: [Result<Int64?, ExtensionLinkError>] = []
        var applied: [Data] = []
        var currentVersion: Result<Int64, ExtensionLinkError> = .success(0)
        var queue: [AccessEvent] = []
        var drainError: ExtensionLinkError?
        var drainMaxes: [Int] = []
    }

    private let state = Mutex(State())
    let applyCalls = CallLatch()
    let drainCalls = CallLatch()
    let currentVersionCalls = CallLatch()

    /// Each `apply` consumes one entry (`nil` means "echo the policy's version"); the last one repeats.
    func scriptApply(_ results: Result<Int64?, ExtensionLinkError>...) {
        state.withLock { $0.applyScript = results }
    }

    func setCurrentVersion(_ result: Result<Int64, ExtensionLinkError>) {
        state.withLock { $0.currentVersion = result }
    }

    func enqueue(_ events: [AccessEvent]) {
        state.withLock { $0.queue.append(contentsOf: events) }
    }

    func setDrainError(_ error: ExtensionLinkError?) {
        state.withLock { $0.drainError = error }
    }

    var applied: [Data] {
        state.withLock { $0.applied }
    }

    var drainMaxes: [Int] {
        state.withLock { $0.drainMaxes }
    }

    func apply(policy: Data) async throws -> Int64 {
        let outcome = state.withLock { state -> Result<Int64?, ExtensionLinkError> in
            state.applied.append(policy)
            if state.applyScript.count > 1 {
                return state.applyScript.removeFirst()
            }
            return state.applyScript.first ?? .success(nil)
        }
        applyCalls.increment()
        if let version = try outcome.get() {
            return version
        }
        return Self.version(of: policy)
    }

    func currentPolicyVersion() async throws -> Int64 {
        currentVersionCalls.increment()
        return try state.withLock { $0.currentVersion }.get()
    }

    func drainEvents(max: Int) async throws -> [AccessEvent] {
        let result = state.withLock { state -> Result<[AccessEvent], ExtensionLinkError> in
            state.drainMaxes.append(max)
            if let error = state.drainError {
                return .failure(error)
            }
            let taken = Array(state.queue.prefix(max))
            state.queue.removeFirst(taken.count)
            return .success(taken)
        }
        drainCalls.increment()
        return try result.get()
    }

    func liveEvents() -> AsyncStream<AccessEvent> {
        AsyncStream { $0.finish() }
    }

    static func version(of policy: Data) -> Int64 {
        struct Probe: Decodable { let version: Int64 }
        return (try? JSONDecoder().decode(Probe.self, from: policy))?.version ?? -1
    }
}
