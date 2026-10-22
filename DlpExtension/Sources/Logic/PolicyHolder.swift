import CoreBridge
import Foundation
import Synchronization

/// Lock-protected slot for the active policy engine, read from the synchronous Endpoint Security handler.
final class PolicyHolder: Sendable {
    private struct State {
        var engine: WDEngine?
        var version: Int64 = 0
    }

    private let state = Mutex(State())

    /// Activates the policy; the reported version always comes from the policy itself.
    func set(policy: WDPolicy) {
        let engine = WDEngine(policy: policy)
        state.withLock {
            $0.engine = engine
            $0.version = policy.version
        }
    }

    /// Returns the holder to the allow-everything state.
    func clear() {
        state.withLock {
            $0.engine = nil
            $0.version = 0
        }
    }

    func engine() -> WDEngine? {
        state.withLock { $0.engine }
    }

    var version: Int64 {
        state.withLock { $0.version }
    }

    /// True when the path can be answered "allow" without evaluating: no policy yet, or the engine's
    /// allocation-free prefilter says no rule can match. Takes raw bytes so no `String` is built.
    func fastPathAllows(_ path: UnsafeRawBufferPointer) -> Bool {
        state.withLock { state in
            guard let engine = state.engine, let base = path.baseAddress else { return true }
            let chars = base.assumingMemoryBound(to: CChar.self)
            return !engine.isPotentiallyProtectedPath(chars, length: UInt(path.count))
        }
    }
}
