import Foundation
import os

/// Moves access events from the extension to the server in bounded batches.
actor EventUploader {
    static let maxBatchCount = 500
    /// Stays under the server's 1 MiB request limit, leaving room for the JSON array framing.
    static let maxBatchBytes = 900 * 1024
    /// Buffer of `drained`; equals `AppStateStore.maxEvents` (the store keeps no more), checked by a test.
    static let drainedBufferSize = 500

    /// Every event drained from the extension, as soon as it is queued for upload (also when the upload later fails).
    /// Single consumer: `AppStateStore`, which dedupes against live events by id.
    nonisolated let drained: AsyncStream<AccessEvent>
    private let drainedContinuation: AsyncStream<AccessEvent>.Continuation
    private let api: any AgentAPI
    private let link: any ExtensionLinking
    private let clock: any Clock<Duration>
    private let interval: Duration
    private let maxPending: Int
    private let store: any PendingEventStoring
    private let log = Logger(subsystem: BundleIDs.app, category: "event-upload")

    private var pending: [AccessEvent] = []
    private var paused = false
    private var flushing = false
    private var nextDelay: Duration?

    var pendingCount: Int {
        pending.count
    }

    /// True after the server rejected the token, until `resume()`.
    var isPaused: Bool {
        paused
    }

    init(
        api: any AgentAPI, link: any ExtensionLinking, clock: any Clock<Duration>,
        interval: Duration = .seconds(5), maxPending: Int = 5000,
        store: any PendingEventStoring = NoPendingEventStore()
    ) {
        self.store = store
        self.api = api
        self.link = link
        self.clock = clock
        self.interval = interval
        self.maxPending = maxPending
        (drained, drainedContinuation) = AsyncStream.makeStream(
            of: AccessEvent.self, bufferingPolicy: .bufferingNewest(Self.drainedBufferSize)
        )
    }

    deinit {
        drainedContinuation.finish()
    }

    /// Ticks until cancelled. After `unauthorized` nothing is drained or sent until `resume()`.
    func run() async {
        restorePending()
        while !Task.isCancelled {
            await tick()
            let delay = nextDelay ?? interval
            nextDelay = nil
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    func flushNow() async {
        await tick()
    }

    func resume() {
        paused = false
    }

    /// Puts the events saved by a previous run ahead of anything drained later. They are not yielded on `drained`.
    private func restorePending() {
        do {
            pending = try store.load() + pending
        } catch {
            log.error("could not load pending events, starting empty")
        }
        if trimPending() {
            persist()
        }
    }

    @discardableResult
    private func trimPending() -> Bool {
        guard pending.count > maxPending else { return false }
        let dropped = pending.count - maxPending
        pending.removeFirst(dropped)
        log.error("event buffer full, dropped \(dropped) oldest events")
        return true
    }

    private func persist() {
        do {
            try store.save(pending)
        } catch {
            log.error("could not save pending events")
        }
    }

    private func tick() async {
        guard !paused, !flushing else { return }
        flushing = true
        defer { flushing = false }
        await drain()
        await upload()
    }

    /// Pulls events out of the extension, bounding the work done per tick; the rest stays there.
    private func drain() async {
        var drained = 0
        while drained < maxPending * 4 {
            do {
                let events = try await link.drainEvents(max: Self.maxBatchCount)
                pending.append(contentsOf: events)
                trimPending()
                if !events.isEmpty {
                    persist()
                }
                for event in events {
                    drainedContinuation.yield(event)
                }
                drained += events.count
                if events.count < Self.maxBatchCount {
                    break
                }
            } catch {
                break
            }
        }
    }

    private func upload() async {
        var countLimit = Self.maxBatchCount
        while !pending.isEmpty {
            let batch = Array(pending.prefix(nextBatchSize(limit: countLimit)))
            do {
                try await api.postEvents(batch)
                pending.removeFirst(batch.count)
                persist()
            } catch AgentAPIError.payloadTooLarge {
                if batch.count > 1 {
                    countLimit = max(1, batch.count / 2)
                } else {
                    pending.removeFirst()
                    persist()
                    log.error("dropped one event that is too large to upload")
                }
            } catch AgentAPIError.invalidBatch {
                pending.removeFirst(batch.count)
                persist()
                log.error("server rejected a batch of \(batch.count) events, dropped it")
            } catch AgentAPIError.unauthorized {
                paused = true
                return
            } catch let AgentAPIError.throttled(retryAfter) {
                nextDelay = retryAfter
                return
            } catch {
                return
            }
        }
    }

    /// How many leading events fit into one batch by count and by encoded size (at least one).
    private func nextBatchSize(limit: Int) -> Int {
        var bytes = 2
        var size = 0
        for event in pending.prefix(limit) {
            let encoded = ((try? AccessEvent.uploadPayload([event]).count) ?? Self.maxBatchBytes) - 1
            if size > 0, bytes + encoded > Self.maxBatchBytes {
                break
            }
            bytes += encoded
            size += 1
        }
        return max(size, 1)
    }
}
