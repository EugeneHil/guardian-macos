import Foundation

/// Implemented by whatever receives access events from the Endpoint Security adapter.
protocol EventRecording: Sendable {
    func record(_ event: AccessEvent) async
}

/// Bounded, deduplicating buffer of access events waiting for upload.
actor EventQueue: EventRecording {
    private struct Key: Hashable {
        let processPath: String
        let file: String
        let decision: AccessDecision
    }

    private struct Seen {
        let time: Duration
        let sequence: Int
    }

    private let capacity: Int
    private let dedupeWindow: Duration
    /// Time elapsed on the injected clock since the queue was created.
    private let elapsed: @Sendable () -> Duration
    private let continuation: AsyncStream<AccessEvent>.Continuation
    private var events: [AccessEvent] = []
    private var lastSeen: [Key: Seen] = [:]
    private var sequence = 0

    /// Single consumer. Keeps the newest 100 events; yielding never blocks.
    nonisolated let updates: AsyncStream<AccessEvent>

    var count: Int {
        events.count
    }

    init(
        capacity: Int = 1000, dedupeWindow: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.capacity = max(1, capacity)
        self.dedupeWindow = dedupeWindow
        elapsed = Self.elapsedSinceNow(of: clock)
        (updates, continuation) = AsyncStream.makeStream(of: AccessEvent.self, bufferingPolicy: .bufferingNewest(100))
    }

    private static func elapsedSinceNow<C: Clock>(
        of clock: C
    ) -> @Sendable () -> Duration where C.Duration == Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }

    func record(_ event: AccessEvent) {
        let now = elapsed()
        let key = Key(processPath: event.process.path, file: event.file, decision: event.decision)
        if let seen = lastSeen[key], now - seen.time < dedupeWindow {
            return
        }
        sequence += 1
        lastSeen[key] = Seen(time: now, sequence: sequence)
        if lastSeen.count > 2 * capacity {
            pruneLastSeen(now: now)
        }
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        continuation.yield(event)
    }

    /// Removes and returns up to `max` events, oldest first.
    func drain(max: Int) -> [AccessEvent] {
        let taken = Swift.min(Swift.max(0, max), events.count)
        let batch = Array(events.prefix(taken))
        events.removeFirst(taken)
        return batch
    }

    /// Runs once the table holds twice the capacity (amortized): forgets expired keys, then keeps only the most
    /// recent `capacity` live ones.
    private func pruneLastSeen(now: Duration) {
        lastSeen = lastSeen.filter { now - $0.value.time < dedupeWindow }
        guard lastSeen.count > capacity else { return }
        let newest = lastSeen.sorted { $0.value.sequence > $1.value.sequence }.prefix(capacity)
        lastSeen = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}
