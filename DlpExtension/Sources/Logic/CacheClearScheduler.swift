import Synchronization

/// Outcome of one kernel cache clear (`es_clear_cache`).
enum CacheClearResult: Sendable, Equatable {
    case cleared
    /// Rate limited by the kernel (`ES_CLEAR_CACHE_RESULT_ERR_THROTTLE`).
    case throttled
    /// Any other failure (`ES_CLEAR_CACHE_RESULT_ERR_INTERNAL`).
    case failed
}

/// Makes ES cache clears reliable: `es_clear_cache` is rate limited, so a clear requested shortly after another one
/// may be refused and leave stale cached allows behind. Requests only set a flag (never touching the kernel, so they
/// are safe from the ES handler); one background task performs the clear and retries a refused one with backoff
/// until it succeeds. Requests arriving while a clear is in progress are coalesced into one more clear afterwards.
final class CacheClearScheduler: CacheClearing, Sendable {
    private struct State {
        var pending = false
        var working = false
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
    }

    /// Shared with the worker task, which must not retain the scheduler itself.
    private final class Shared: Sendable {
        let state = Mutex(State())

        /// Takes the pending request (marking the worker busy), or marks it idle and wakes idle waiters.
        func takePending() -> Bool {
            let (taken, waiters) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                if state.pending {
                    state.pending = false
                    state.working = true
                    return (true, [])
                }
                state.working = false
                let waiters = state.idleWaiters
                state.idleWaiters = []
                return (false, waiters)
            }
            for waiter in waiters {
                waiter.resume()
            }
            return taken
        }
    }

    private let shared: Shared
    private let signal: AsyncStream<Void>.Continuation
    private let worker: Task<Void, Never>

    init(
        clock: any Clock<Duration> = ContinuousClock(), initialBackoff: Duration = .milliseconds(50),
        maxBackoff: Duration = .seconds(1), log: @escaping @Sendable (String) -> Void,
        clear: @escaping @Sendable () -> CacheClearResult
    ) {
        let (signals, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.signal = signal
        let sleep = Self.sleeper(on: clock)
        let shared = Shared()
        self.shared = shared
        worker = Task {
            for await _ in signals {
                while shared.takePending() {
                    var backoff = initialBackoff
                    var attempts = 1
                    while clear() != .cleared {
                        do {
                            try await sleep(backoff)
                        } catch {
                            return // cancelled: the scheduler is gone
                        }
                        backoff = min(backoff * 2, maxBackoff)
                        attempts += 1
                    }
                    if attempts > 1 {
                        log("ES cache cleared after \(attempts) attempts")
                    }
                }
            }
        }
    }

    deinit {
        worker.cancel()
        signal.finish()
    }

    /// Asks for a cache clear. Non-blocking and allocation-light; never calls the kernel.
    func request() {
        let first = shared.state.withLock { state -> Bool in
            defer { state.pending = true }
            return !state.pending
        }
        if first {
            signal.yield()
        }
    }

    func clearCache() {
        request()
    }

    /// Returns once no clear is requested or in progress (for tests and diagnostics).
    func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = shared.state.withLock { state -> Bool in
                if !state.pending, !state.working {
                    return true
                }
                state.idleWaiters.append(continuation)
                return false
            }
            if idle {
                continuation.resume()
            }
        }
    }

    private static func sleeper<C: Clock>(
        on clock: C
    ) -> @Sendable (Duration) async throws -> Void where C.Duration == Duration {
        { duration in try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil) }
    }
}
