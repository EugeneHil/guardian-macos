import Foundation

/// Presentation model for one access event row. Only a denied decision counts as blocked.
struct EventRowModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let badge: BadgeKind
    let badgeText: String

    static let unknownProcess = "Unknown process"

    init(event: AccessEvent, now: Date, home: String) {
        id = event.id
        let process = Self.processName(for: event)
        let file = (event.file as NSString).lastPathComponent
        title = "\(process) → \(file)"
        let path = Self.abbreviate(event.file, home: home)
        subtitle = "\(path) · \(RelativeTime.string(from: event.timestamp, now: now))"
        switch event.decision {
        case .deny:
            badge = .blocked
            badgeText = "Blocked"
        case .allow:
            badge = .ok
            badgeText = "Allowed"
        }
    }

    /// A helper process is reported under the app that is responsible for it, when that resolves.
    private static func processName(for event: AccessEvent) -> String {
        for identity in [event.responsible, event.process] {
            let name = identity.map { ($0.path as NSString).lastPathComponent } ?? ""
            if !name.isEmpty {
                return name
            }
        }
        return unknownProcess
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
