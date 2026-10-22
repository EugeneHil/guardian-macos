import Foundation
import Observation

/// Presentation logic for the menu bar popover.
@MainActor @Observable
final class PopoverViewModel {
    static let recentCount = 5

    @ObservationIgnored private let store: AppStateStore
    @ObservationIgnored private let syncNow: @Sendable () async -> Void
    @ObservationIgnored private let openSettingsAction: @MainActor () -> Void
    @ObservationIgnored private let openEventsAction: @MainActor () -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let home: String

    init(
        store: AppStateStore, syncNow: @escaping @Sendable () async -> Void,
        openSettings: @escaping @MainActor () -> Void, openEvents: @escaping @MainActor () -> Void,
        now: @escaping @Sendable () -> Date, home: String = NSHomeDirectory()
    ) {
        self.store = store
        self.syncNow = syncNow
        openSettingsAction = openSettings
        openEventsAction = openEvents
        self.now = now
        self.home = home
    }

    /// The extension is running and a policy version is known (applied, even if the server is unreachable now).
    var isProtectionActive: Bool {
        store.extensionState == .active && store.lastPolicyVersion != nil
    }

    var statusTitle: String {
        switch store.extensionState {
        case .active where isProtectionActive: "Protection active"
        case .awaitingApproval: "Awaiting approval in System Settings"
        case .notInstalled: "Extension not installed"
        case .active, .unknown, .failed: "Protection off"
        }
    }

    var policyLine: String {
        switch store.syncState {
        case let .synced(version, syncedAt):
            "Policy v\(version) · synced \(RelativeTime.string(from: syncedAt, now: now()))"
        case let .unreachable(lastVersion?):
            "Policy v\(lastVersion) · server unreachable"
        case .unauthorized:
            "Check agent token"
        case let .extensionUnavailable(version) where version > 0:
            "Policy v\(version) · extension unavailable"
        case .throttled:
            "Server busy · retrying"
        case .notConfigured, .idle, .unreachable(nil), .extensionUnavailable:
            "No policy yet"
        }
    }

    var recentRows: [EventRowModel] {
        store.events.prefix(Self.recentCount).map { EventRowModel(event: $0, now: now(), home: home) }
    }

    var blockedCount: Int {
        store.events.count(where: { $0.decision == .deny })
    }

    func syncNowTapped() async {
        await syncNow()
    }

    func openSettingsTapped() {
        openSettingsAction()
    }

    func openEventsTapped() {
        openEventsAction()
    }
}
