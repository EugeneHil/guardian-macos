import Foundation
import Observation

/// Single source of truth for the UI: the latest sync state, extension state and a bounded event list.
@MainActor @Observable
final class AppStateStore {
    nonisolated static let maxEvents = 500

    private(set) var syncState: SyncState = .idle
    private(set) var extensionState: ExtensionState = .unknown
    /// Newest first by timestamp, unique by event id, capped at `maxEvents` (the oldest is evicted). Once full, an
    /// event not newer than the oldest kept one is ignored, so an evicted event never comes back.
    private(set) var events: [AccessEvent] = []
    /// The last policy version the extension is known to enforce. Updated by `.synced` and by `.unreachable`
    /// with a version; kept across throttled, unauthorized, idle and not-configured transitions. An
    /// `.extensionUnavailable` state never updates it: the extension did not receive that policy.
    private(set) var lastPolicyVersion: Int64?

    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private let syncStream: AsyncStream<SyncState>
    @ObservationIgnored private let extensionStream: AsyncStream<ExtensionState>
    @ObservationIgnored private let eventStream: AsyncStream<AccessEvent>
    @ObservationIgnored private let drainedStream: AsyncStream<AccessEvent>
    @ObservationIgnored private var knownIDs: Set<UUID> = []

    init(
        sync: AsyncStream<SyncState>, extensionStates: AsyncStream<ExtensionState>, events: AsyncStream<AccessEvent>,
        drained: AsyncStream<AccessEvent>, now: @escaping @Sendable () -> Date
    ) {
        syncStream = sync
        extensionStream = extensionStates
        eventStream = events
        drainedStream = drained
        self.now = now
    }

    /// Consumes the four streams until they finish or the calling task is cancelled. Live and drained events are
    /// merged and deduplicated by id.
    func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.consumeSync() }
            group.addTask { await self.consumeExtension() }
            group.addTask { await self.consumeEvents(self.eventStream) }
            group.addTask { await self.consumeEvents(self.drainedStream) }
        }
    }

    private func consumeSync() async {
        for await state in syncStream {
            syncState = state
            switch state {
            case let .synced(version, _): lastPolicyVersion = version
            case let .unreachable(lastVersion?, _): lastPolicyVersion = lastVersion
            default: break
            }
        }
    }

    private func consumeExtension() async {
        for await state in extensionStream {
            extensionState = state
        }
    }

    private func consumeEvents(_ stream: AsyncStream<AccessEvent>) async {
        for await event in stream {
            insert(event)
        }
    }

    private func insert(_ event: AccessEvent) {
        let isFull = events.count >= Self.maxEvents
        if isFull, let oldest = events.last, event.timestamp <= oldest.timestamp {
            return
        }
        guard knownIDs.insert(event.id).inserted else { return }
        let index = events.firstIndex { $0.timestamp < event.timestamp } ?? events.endIndex
        events.insert(event, at: index)
        if events.count > Self.maxEvents {
            let dropped = events.removeLast()
            knownIDs.remove(dropped.id)
        }
    }
}
