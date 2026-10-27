import CoreBridge
import Foundation
import Synchronization

/// Lock-protected slot for the active policy engine, read from the synchronous Endpoint Security handler.
final class PolicyHolder: Sendable {
    private struct State {
        var engine: GDEngine?
        var version: Int64 = 0
        var generation: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Activates the policy; the reported version always comes from the policy itself.
    func set(policy: GDPolicy) {
        replaceEngine(with: GDEngine(policy: policy), version: policy.version)
    }

    /// Returns the holder to the allow-everything state.
    func clear() {
        replaceEngine(with: nil, version: 0)
    }

    func engine() -> GDEngine? {
        state.withLock { $0.engine }
    }

    var version: Int64 {
        state.withLock { $0.version }
    }

    /// Bumped by every `set(policy:)` and `clear()`; a fast-path verdict is only valid for the generation it was
    /// taken under.
    var generation: UInt64 {
        state.withLock { $0.generation }
    }

    /// True when the path can be answered "allow" without evaluating: no policy yet, or the engine's
    /// allocation-free prefilter says no rule can match. Takes raw bytes so no `String` is built.
    func fastPathAllows(_ path: UnsafeRawBufferPointer) -> Bool {
        fastPathDecision(path).allows
    }

    /// `fastPathAllows` together with the generation it was decided under, read in one lock acquisition, so the
    /// caller can tell whether the policy changed before it acted on the verdict. Allocation-free.
    func fastPathDecision(_ path: UnsafeRawBufferPointer) -> (allows: Bool, generation: UInt64) {
        state.withLock { state in
            guard let engine = state.engine, let base = path.baseAddress else { return (true, state.generation) }
            let chars = base.assumingMemoryBound(to: CChar.self)
            return (!engine.isPotentiallyProtectedPath(chars, length: UInt(path.count)), state.generation)
        }
    }

    /// Swaps the engine under the lock; the previous one is released only after unlocking, so its C++ teardown
    /// never runs while the Endpoint Security handler waits on the lock.
    private func replaceEngine(with engine: GDEngine?, version: Int64) {
        let previous = state.withLock { state -> GDEngine? in
            let previous = state.engine
            state.engine = engine
            state.version = version
            state.generation &+= 1
            return previous
        }
        withExtendedLifetime(previous) {}
    }
}
