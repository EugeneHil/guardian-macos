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
        title = file.isEmpty ? process : "\(process) → \(file)"
        let path = Self.abbreviate(event.file, home: home)
        subtitle = "\(path) · \(RelativeTime.string(from: event.timestamp, now: now))"
        switch event.decision {
        case .deny:
            badge = .blocked
            badgeText = "Blocked"
        case .allow:
            badge = .ok
            badgeText = "OK"
        }
    }

    /// The opener's own name, unless it is a helper of the responsible app: it lives inside the responsible
    /// process's `*.app/` bundle (as a different executable) or its file name contains "Helper".
    private static func processName(for event: AccessEvent) -> String {
        let opener = event.process.path
        let openerName = (opener as NSString).lastPathComponent
        let responsible = event.responsible?.path ?? ""
        let responsibleName = (responsible as NSString).lastPathComponent
        if !responsibleName.isEmpty, isHelper(opener: opener, responsible: responsible) {
            return responsibleName
        }
        return openerName.isEmpty ? unknownProcess : openerName
    }

    private static func isHelper(opener: String, responsible: String) -> Bool {
        if (opener as NSString).lastPathComponent.contains("Helper") {
            return true
        }
        guard let bundle = responsible.range(of: ".app/") else { return false }
        let prefix = String(responsible[..<bundle.upperBound])
        return opener.hasPrefix(prefix) && opener != responsible
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        var home = home
        while home.hasSuffix("/") {
            home.removeLast()
        }
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
