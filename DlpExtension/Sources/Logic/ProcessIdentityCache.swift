import Synchronization

/// Identities resolved per process instance. A resolved identity stays until the cache is full (then everything is
/// dropped); a failed lookup is remembered only for `failureTTL`, so a transient failure is retried soon.
final class ProcessIdentityCache: Sendable {
    private struct Entry {
        let identity: ProcessIdentity?
        let storedAt: Duration
    }

    private let capacity: Int
    private let failureTTL: Duration
    private let elapsed: @Sendable () -> Duration
    private let entries = Mutex<[ProcessToken: Entry]>([:])

    init(capacity: Int = 1024, failureTTL: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock()) {
        self.capacity = max(1, capacity)
        self.failureTTL = failureTTL
        elapsed = Self.elapsedSinceNow(of: clock)
    }

    var count: Int {
        entries.withLock { $0.count }
    }

    /// `nil` when not cached; `.some(nil)` for a cached (unexpired) failure.
    func lookup(_ token: ProcessToken) -> ProcessIdentity?? {
        let now = elapsed()
        return entries.withLock { entries -> ProcessIdentity?? in
            guard let entry = entries[token] else { return nil }
            if entry.identity == nil, now - entry.storedAt >= failureTTL {
                entries[token] = nil
                return nil
            }
            return .some(entry.identity)
        }
    }

    func store(_ identity: ProcessIdentity?, for token: ProcessToken) {
        let now = elapsed()
        entries.withLock { entries in
            if entries[token] == nil, entries.count >= capacity {
                entries.removeAll(keepingCapacity: true)
            }
            entries[token] = Entry(identity: identity, storedAt: now)
        }
    }

    private static func elapsedSinceNow<C: Clock>(
        of clock: C
    ) -> @Sendable () -> Duration where C.Duration == Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }
}
