import Foundation
import Observation

/// Presentation logic for the events window.
@MainActor @Observable
final class EventsViewModel {
    var blockedOnly = false

    @ObservationIgnored private let store: AppStateStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let home: String

    init(store: AppStateStore, now: @escaping @Sendable () -> Date, home: String = NSHomeDirectory()) {
        self.store = store
        self.now = now
        self.home = home
    }

    var rows: [EventRowModel] {
        let current = now()
        return store.events
            .filter { !blockedOnly || $0.decision == .deny }
            .map { EventRowModel(event: $0, now: current, home: home) }
    }
}
