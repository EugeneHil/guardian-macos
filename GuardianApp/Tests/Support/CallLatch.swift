import Synchronization

/// Counts events and lets a test suspend until a count is reached, without polling or yielding.
final class CallLatch: Sendable {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var count = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    var count: Int {
        state.withLock { $0.count }
    }

    func increment() {
        let ready = state.withLock { state -> [Waiter] in
            state.count += 1
            let ready = state.waiters.filter { $0.count <= state.count }
            state.waiters.removeAll { $0.count <= state.count }
            return ready
        }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func wait(for count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.count >= count {
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
}
