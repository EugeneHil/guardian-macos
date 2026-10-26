import Synchronization

/// What the recorder measures. The labels are the names used in the log lines.
enum DiagnosticMetric: Int, CaseIterable, Sendable {
    /// Endpoint Security message to deadline at handler entry, unclamped, for every `AUTH_OPEN`.
    case deadlineMargin
    /// Handler entry to after the response call of a fast-path allow.
    case fastPath
    /// Handler entry to the response of a candidate, answered "allow" (including the watchdog).
    case candidateAllow
    /// Handler entry to the response of a candidate, answered "deny".
    case candidateDeny
    /// Resolver call answered from the identity cache.
    case lookupCached
    /// Resolver call that ran the Security lookup and found an identity.
    case lookupResolved
    /// Resolver call that ran the Security lookup and found nothing.
    case lookupFailed

    var label: String {
        switch self {
        case .deadlineMargin: "deadlineMargin"
        case .fastPath: "fastPath"
        case .candidateAllow: "candidateAllow"
        case .candidateDeny: "candidateDeny"
        case .lookupCached: "lookupCached"
        case .lookupResolved: "lookupResolved"
        case .lookupFailed: "lookupFailed"
        }
    }
}

/// Plain event counters. The labels are the names used in the log line.
enum DiagnosticCounter: Int, CaseIterable, Sendable {
    case responsibleTokenZero
    case responsibleTokenSet
    case responsibleIsOpener
    case resolvedTeamIdPresent
    case resolvedTeamIdEmpty

    var label: String {
        switch self {
        case .responsibleTokenZero: "responsibleTokenZero"
        case .responsibleTokenSet: "responsibleTokenSet"
        case .responsibleIsOpener: "responsibleIsOpener"
        case .resolvedTeamIdPresent: "resolvedTeamIdPresent"
        case .resolvedTeamIdEmpty: "resolvedTeamIdEmpty"
        }
    }
}

/// Count, min, max, sum (nanoseconds) and a log2 histogram in microseconds. Bucket 0 holds values below 1 us,
/// bucket k (1 ..< last) values below 2^k us, the last bucket everything above.
struct DiagnosticHistogram: Sendable, Equatable {
    static let bucketCount = 28

    private(set) var count: UInt64 = 0
    private(set) var minimum: UInt64 = 0
    private(set) var maximum: UInt64 = 0
    private(set) var sum: UInt64 = 0
    private(set) var buckets = [UInt64](repeating: 0, count: bucketCount)

    static func bucket(forNanoseconds nanoseconds: UInt64) -> Int {
        let micros = nanoseconds / 1000
        return min(UInt64.bitWidth - micros.leadingZeroBitCount, bucketCount - 1)
    }

    /// Exclusive upper bound of a bucket in microseconds; nil for the open last bucket.
    static func upperBoundMicroseconds(ofBucket bucket: Int) -> UInt64? {
        bucket >= bucketCount - 1 ? nil : UInt64(1) << UInt64(bucket)
    }

    /// Allocation-free: only in-place integer updates.
    mutating func add(_ nanoseconds: UInt64) {
        if count == 0 || nanoseconds < minimum {
            minimum = nanoseconds
        }
        if nanoseconds > maximum {
            maximum = nanoseconds
        }
        let (total, overflow) = sum.addingReportingOverflow(nanoseconds)
        sum = overflow ? UInt64.max : total
        count += 1
        buckets[Self.bucket(forNanoseconds: nanoseconds)] += 1
    }

    /// Upper bound in microseconds of the bucket holding the `fraction` quantile (the maximum for the open bucket).
    func quantileBoundMicroseconds(_ fraction: Double) -> UInt64 {
        guard count > 0 else { return 0 }
        let target = max(1, UInt64((Double(count) * fraction).rounded(.up)))
        var seen: UInt64 = 0
        for (index, value) in buckets.enumerated() {
            seen += value
            if seen >= target {
                return Self.upperBoundMicroseconds(ofBucket: index) ?? maximum / 1000
            }
        }
        return maximum / 1000
    }
}

/// Always-on, cheap measurements for the VM checklist (items 5, 6, 7, 13). Safe to call from the synchronous
/// Endpoint Security handler: one short lock and in-place integer updates, no allocation.
final class DiagnosticsRecorder: Sendable {
    struct Snapshot: Sendable, Equatable {
        var metrics: [DiagnosticMetric: DiagnosticHistogram] = [:]
        var counters: [DiagnosticCounter: UInt64] = [:]
    }

    private struct State {
        var metrics = [DiagnosticHistogram](repeating: DiagnosticHistogram(), count: DiagnosticMetric.allCases.count)
        var counters = [UInt64](repeating: 0, count: DiagnosticCounter.allCases.count)
        /// Number of updates so far; a summary is written only when it moved.
        var updates: UInt64 = 0
        var loggedUpdates: UInt64 = 0
    }

    private let state = Mutex(State())

    func record(_ metric: DiagnosticMetric, nanoseconds: UInt64) {
        state.withLock { state in
            state.metrics[metric.rawValue].add(nanoseconds)
            state.updates += 1
        }
    }

    /// The fast-path pair under a single lock.
    func recordFastPath(marginNanoseconds: UInt64, durationNanoseconds: UInt64) {
        state.withLock { state in
            state.metrics[DiagnosticMetric.deadlineMargin.rawValue].add(marginNanoseconds)
            state.metrics[DiagnosticMetric.fastPath.rawValue].add(durationNanoseconds)
            state.updates += 1
        }
    }

    func increment(_ counter: DiagnosticCounter) {
        state.withLock { state in
            state.counters[counter.rawValue] += 1
            state.updates += 1
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { Self.snapshot(of: $0) }
    }

    /// Writes the summary lines when something was recorded since the last call. Returns whether it wrote.
    @discardableResult
    func snapshotAndLog(log: (String) -> Void) -> Bool {
        let snapshot = state.withLock { state -> Snapshot? in
            guard state.updates != state.loggedUpdates else { return nil }
            state.loggedUpdates = state.updates
            return Self.snapshot(of: state)
        }
        guard let snapshot else { return false }
        for line in Self.summaryLines(snapshot) {
            log(line)
        }
        return true
    }

    /// Logs a summary every `interval` until cancelled.
    func logPeriodically<C: Clock>(
        every interval: Duration = .seconds(60), clock: C = ContinuousClock(), log: @Sendable (String) -> Void
    ) async where C.Duration == Duration {
        while !Task.isCancelled {
            do {
                try await clock.sleep(until: clock.now.advanced(by: interval), tolerance: nil)
            } catch {
                return
            }
            snapshotAndLog(log: log)
        }
    }

    private static func snapshot(of state: State) -> Snapshot {
        var snapshot = Snapshot()
        for metric in DiagnosticMetric.allCases where state.metrics[metric.rawValue].count > 0 {
            snapshot.metrics[metric] = state.metrics[metric.rawValue]
        }
        for counter in DiagnosticCounter.allCases where state.counters[counter.rawValue] > 0 {
            snapshot.counters[counter] = state.counters[counter.rawValue]
        }
        return snapshot
    }

    /// One line per metric with data, then one line with the non-zero counters. Fixed names and numbers only.
    static func summaryLines(_ snapshot: Snapshot) -> [String] {
        var lines: [String] = []
        for metric in DiagnosticMetric.allCases {
            guard let histogram = snapshot.metrics[metric], histogram.count > 0 else { continue }
            let mean = histogram.sum / histogram.count
            lines.append(
                "diag \(metric.label) n=\(histogram.count) min=\(histogram.minimum / 1000)us "
                    + "mean=\(mean / 1000)us max=\(histogram.maximum / 1000)us "
                    + "p50<=\(histogram.quantileBoundMicroseconds(0.5))us "
                    + "p99<=\(histogram.quantileBoundMicroseconds(0.99))us"
            )
        }
        let counters = DiagnosticCounter.allCases.compactMap { counter -> String? in
            guard let value = snapshot.counters[counter] else { return nil }
            return "\(counter.label)=\(value)"
        }
        if !counters.isEmpty {
            lines.append("diag counters " + counters.joined(separator: " "))
        }
        return lines
    }
}
