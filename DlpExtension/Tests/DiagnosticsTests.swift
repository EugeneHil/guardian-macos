import Synchronization
import XCTest

final class DiagnosticsTests: XCTestCase {
    // MARK: Histogram

    func testBucketBoundaries() {
        func bucket(_ micros: UInt64) -> Int {
            DiagnosticHistogram.bucket(forNanoseconds: micros * 1000)
        }
        XCTAssertEqual(DiagnosticHistogram.bucket(forNanoseconds: 0), 0)
        XCTAssertEqual(DiagnosticHistogram.bucket(forNanoseconds: 999), 0) // < 1 us
        XCTAssertEqual(bucket(1), 1) // < 2 us
        XCTAssertEqual(bucket(2), 2) // < 4 us
        XCTAssertEqual(bucket(3), 2)
        XCTAssertEqual(bucket(4), 3)
        XCTAssertEqual(bucket(1023), 10)
        XCTAssertEqual(bucket(1024), 11)
        XCTAssertEqual(DiagnosticHistogram.bucket(forNanoseconds: UInt64.max), DiagnosticHistogram.bucketCount - 1)
        XCTAssertEqual(DiagnosticHistogram.upperBoundMicroseconds(ofBucket: 0), 1)
        XCTAssertEqual(DiagnosticHistogram.upperBoundMicroseconds(ofBucket: 3), 8)
        XCTAssertNil(DiagnosticHistogram.upperBoundMicroseconds(ofBucket: DiagnosticHistogram.bucketCount - 1))
    }

    func testCountMinMaxSumAndBuckets() {
        var histogram = DiagnosticHistogram()
        for value: UInt64 in [5000, 1000, 9000] {
            histogram.add(value)
        }
        XCTAssertEqual(histogram.count, 3)
        XCTAssertEqual(histogram.minimum, 1000)
        XCTAssertEqual(histogram.maximum, 9000)
        XCTAssertEqual(histogram.sum, 15000)
        XCTAssertEqual(histogram.buckets.reduce(0, +), 3)
        XCTAssertEqual(histogram.buckets[1], 1) // 1 us
        XCTAssertEqual(histogram.buckets[3], 1) // 5 us
        XCTAssertEqual(histogram.buckets[4], 1) // 9 us
    }

    func testSumSaturates() {
        var histogram = DiagnosticHistogram()
        histogram.add(UInt64.max)
        histogram.add(10)
        XCTAssertEqual(histogram.sum, UInt64.max)
        XCTAssertEqual(histogram.count, 2)
    }

    func testQuantileBounds() {
        var histogram = DiagnosticHistogram()
        for _ in 0 ..< 99 {
            histogram.add(3000) // bucket < 4 us
        }
        histogram.add(100_000_000) // 100 ms
        XCTAssertEqual(histogram.quantileBoundMicroseconds(0.5), 4)
        XCTAssertEqual(histogram.quantileBoundMicroseconds(0.99), 4)
        XCTAssertEqual(histogram.quantileBoundMicroseconds(1.0), 131_072)
    }

    func testOpenBucketReportsTheMaximum() {
        var histogram = DiagnosticHistogram()
        histogram.add(1_000_000_000_000) // 1000 s
        XCTAssertEqual(histogram.quantileBoundMicroseconds(0.99), 1_000_000_000)
    }

    // MARK: Recorder

    func testRecorderKeepsMetricsApart() {
        let recorder = DiagnosticsRecorder()
        recorder.record(.candidateAllow, nanoseconds: 2000)
        recorder.record(.candidateDeny, nanoseconds: 4000)
        recorder.recordFastPath(marginNanoseconds: 3_000_000_000, durationNanoseconds: 700)
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.metrics[.candidateAllow]?.count, 1)
        XCTAssertEqual(snapshot.metrics[.candidateDeny]?.maximum, 4000)
        XCTAssertEqual(snapshot.metrics[.deadlineMargin]?.maximum, 3_000_000_000)
        XCTAssertEqual(snapshot.metrics[.fastPath]?.maximum, 700)
        XCTAssertNil(snapshot.metrics[.lookupCached])
    }

    func testCounters() {
        let recorder = DiagnosticsRecorder()
        recorder.increment(.responsibleTokenZero)
        recorder.increment(.responsibleTokenSet)
        recorder.increment(.responsibleTokenSet)
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.counters[.responsibleTokenZero], 1)
        XCTAssertEqual(snapshot.counters[.responsibleTokenSet], 2)
        XCTAssertNil(snapshot.counters[.responsibleIsOpener])
    }

    func testRecorderIsSafeFromConcurrentUpdates() async {
        let recorder = DiagnosticsRecorder()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    for index in 0 ..< 1000 {
                        recorder.record(.lookupResolved, nanoseconds: UInt64(index))
                        recorder.increment(.resolvedTeamIdEmpty)
                        recorder.recordFastPath(marginNanoseconds: 1, durationNanoseconds: 1)
                    }
                }
            }
        }
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.metrics[.lookupResolved]?.count, 8000)
        XCTAssertEqual(snapshot.metrics[.lookupResolved]?.sum, 8 * 499_500)
        XCTAssertEqual(snapshot.counters[.resolvedTeamIdEmpty], 8000)
        XCTAssertEqual(snapshot.metrics[.fastPath]?.count, 8000)
        XCTAssertEqual(snapshot.metrics[.deadlineMargin]?.count, 8000)
    }

    // MARK: Formatter and logging

    func testSummaryLinesUseFixedKeysAndNumbersOnly() {
        let recorder = DiagnosticsRecorder()
        recorder.record(.fastPath, nanoseconds: 3000)
        recorder.record(.fastPath, nanoseconds: 9000)
        recorder.increment(.responsibleTokenSet)
        recorder.increment(.resolvedTeamIdEmpty)
        let lines = DiagnosticsRecorder.summaryLines(recorder.snapshot())
        XCTAssertEqual(lines, [
            "diag fastPath n=2 min=3us mean=6us max=9us p50<=4us p99<=16us",
            "diag counters responsibleTokenSet=1 resolvedTeamIdEmpty=1",
        ])
    }

    func testSummaryLinesAreEmptyWithoutData() {
        XCTAssertEqual(DiagnosticsRecorder.summaryLines(DiagnosticsRecorder().snapshot()), [])
    }

    func testSummaryLinesContainOnlyKnownWords() {
        let recorder = DiagnosticsRecorder()
        for metric in DiagnosticMetric.allCases {
            recorder.record(metric, nanoseconds: 123_456)
        }
        for counter in DiagnosticCounter.allCases {
            recorder.increment(counter)
        }
        let allowed = Set(["diag", "counters", "n", "min", "mean", "max", "p50", "p99"]
            + DiagnosticMetric.allCases.map(\.label) + DiagnosticCounter.allCases.map(\.label))
        for line in DiagnosticsRecorder.summaryLines(recorder.snapshot()) {
            for word in line.split(separator: " ") {
                let name = word.split(whereSeparator: { $0 == "=" || $0 == "<" }).first.map(String.init) ?? ""
                XCTAssertTrue(allowed.contains(name), "unexpected word \(word) in \(line)")
            }
        }
    }

    func testSnapshotAndLogWritesOnlyWhenSomethingChanged() {
        let recorder = DiagnosticsRecorder()
        var lines: [String] = []
        XCTAssertFalse(recorder.snapshotAndLog { lines.append($0) })
        XCTAssertTrue(lines.isEmpty)
        recorder.record(.lookupCached, nanoseconds: 1000)
        XCTAssertTrue(recorder.snapshotAndLog { lines.append($0) })
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(recorder.snapshotAndLog { lines.append($0) })
        XCTAssertEqual(lines.count, 1)
        recorder.increment(.responsibleIsOpener)
        XCTAssertTrue(recorder.snapshotAndLog { lines.append($0) })
        XCTAssertEqual(lines.count, 3) // cumulative: metric line plus counters line
    }

    func testPeriodicLoggingFollowsTheClock() async {
        let recorder = DiagnosticsRecorder()
        let clock = ManualClock()
        let sink = Mutex<[String]>([])
        recorder.record(.fastPath, nanoseconds: 1000)
        let task = Task {
            await recorder.logPeriodically(every: .seconds(60), clock: clock) { line in
                sink.withLock { $0.append(line) }
            }
        }
        await clock.waitForSleepers(1)
        XCTAssertEqual(sink.withLock { $0.count }, 0)
        clock.advance(by: .seconds(60))
        await clock.waitForSleepers(1)
        XCTAssertEqual(sink.withLock { $0.count }, 1)
        clock.advance(by: .seconds(60)) // nothing new: no further line
        await clock.waitForSleepers(1)
        XCTAssertEqual(sink.withLock { $0.count }, 1)
        task.cancel()
        await task.value
    }

    // MARK: Unclamped deadline

    func testUnclampedDeadlineIsNotCapped() {
        let tenSeconds: UInt64 = 10_000_000_000
        XCTAssertEqual(ESDeadline.unclampedNanoseconds(deadline: tenSeconds, now: 0, timebase: (1, 1)), tenSeconds)
        XCTAssertEqual(ESDeadline.unclampedNanoseconds(deadline: 10000, now: 7000, timebase: (125, 3)), 125_000)
    }

    func testUnclampedDeadlineSaturatesOnOverflow() {
        XCTAssertEqual(
            ESDeadline.unclampedNanoseconds(deadline: UInt64.max, now: 0, timebase: (UInt32.max, 1)), UInt64.max
        )
    }

    func testUnclampedDeadlineIsZeroForPastDeadlineOrInvalidTimebase() {
        XCTAssertEqual(ESDeadline.unclampedNanoseconds(deadline: 5, now: 10, timebase: (1, 1)), 0)
        XCTAssertEqual(ESDeadline.unclampedNanoseconds(deadline: 1000, now: 0, timebase: (1, 0)), 0)
        XCTAssertEqual(ESDeadline.unclampedNanoseconds(deadline: 1000, now: 0, timebase: (0, 1)), 0)
    }
}
