import SwiftUI

struct EventRow: View {
    let model: EventRowModel

    var body: some View {
        HStack(spacing: Tokens.Spacing.md) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(model.title)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(model.subtitle)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Tokens.Spacing.sm)
            Badge(model.badgeText, kind: model.badge)
        }
        .padding(.vertical, Tokens.Spacing.sm)
        .padding(.horizontal, Tokens.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

private extension EventRowModel {
    static func sample(_ badge: BadgeKind) -> EventRowModel {
        let event = AccessEvent(
            id: UUID(),
            timestamp: Date(timeIntervalSinceNow: -12),
            process: ProcessIdentity(path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                                     signingId: "", teamId: ""),
            responsible: nil,
            file: "/Users/me/proj/api/secrets.txt",
            decision: badge == .blocked ? .deny : .allow,
            ruleId: nil
        )
        return EventRowModel(event: event, now: Date(), home: "/Users/me")
    }
}

#Preview("EventRow light") {
    VStack {
        EventRow(model: .sample(.blocked))
        EventRow(model: .sample(.ok))
    }
    .frame(width: 320)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.light)
}

#Preview("EventRow dark") {
    VStack {
        EventRow(model: .sample(.blocked))
        EventRow(model: .sample(.ok))
    }
    .frame(width: 320)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.dark)
}
