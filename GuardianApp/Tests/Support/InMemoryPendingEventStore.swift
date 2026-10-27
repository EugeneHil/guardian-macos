import Foundation
import Synchronization

/// A `PendingEventStoring` that keeps events in memory and records every save.
final class InMemoryPendingEventStore: PendingEventStoring, Sendable {
    struct Failure: Error {}

    private struct State {
        var events: [AccessEvent]
        var saves: [[AccessEvent]] = []
        var failSaves = false
    }

    private let state: Mutex<State>

    init(events: [AccessEvent] = []) {
        state = Mutex(State(events: events))
    }

    var events: [AccessEvent] {
        state.withLock { $0.events }
    }

    var saves: [[AccessEvent]] {
        state.withLock { $0.saves }
    }

    func failSaves(_ fail: Bool) {
        state.withLock { $0.failSaves = fail }
    }

    func load() throws -> [AccessEvent] {
        state.withLock { $0.events }
    }

    func save(_ events: [AccessEvent]) throws {
        try state.withLock { state in
            state.saves.append(events)
            if state.failSaves {
                throw Failure()
            }
            state.events = events
        }
    }
}
