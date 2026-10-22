import Synchronization

/// A `Clock` whose time moves only through `advance(by:)`.
/// Sleepers are suspended until the clock reaches their deadline.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration {
        .zero
    }

    /// Number of sleepers currently suspended.
    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Suspends until at least `count` sleepers are suspended, so a following `advance(by:)` cannot race a
    /// `sleep(for:)` that has not computed its deadline yet.
    func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.sleepers.count >= count {
                    return true
                }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let ids = state.sleepers.filter { $0.value.deadline <= state.now }.keys
            return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    func sleep(until deadline: Instant, tolerance _: Duration? = nil) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (ready, satisfied) = state.withLock { state -> (Bool, [Waiter]) in
                    if deadline <= state.now || Task.isCancelled {
                        return (true, [])
                    }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    let count = state.sleepers.count
                    let satisfied = state.waiters.filter { $0.count <= count }
                    state.waiters.removeAll { $0.count <= count }
                    return (false, satisfied)
                }
                for waiter in satisfied {
                    waiter.continuation.resume()
                }
                if ready {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
