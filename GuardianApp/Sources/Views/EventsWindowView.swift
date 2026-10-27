import SwiftUI

/// "All events" window: every event the app has seen this session, newest first, optionally blocked only.
struct EventsWindowView: View {
    @Bindable var model: EventsViewModel

    private static let minWidth: CGFloat = 480
    private static let minHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("All events")
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Spacer()
                Toggle("Blocked only", isOn: $model.blockedOnly)
                    .toggleStyle(.switch)
                    .font(Tokens.Typography.body)
            }
            .padding(Tokens.Spacing.lg)
            Rectangle()
                .fill(Tokens.Palette.border)
                .frame(height: 1)
            if model.rows.isEmpty {
                Text(model.blockedOnly ? "No blocked events" : "No events yet")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.rows) { row in
                    EventRow(model: row)
                        .listRowSeparatorTint(Tokens.Palette.border)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: Self.minWidth, minHeight: Self.minHeight)
        .background(Tokens.Palette.background)
    }
}

#if DEBUG
    private struct EventsPreview: View {
        let store: AppStateStore

        var body: some View {
            EventsWindowView(model: PreviewFixtures.events(store))
                .task { await store.run() }
        }
    }

    #Preview("Events light") {
        EventsPreview(store: PreviewFixtures.store())
            .preferredColorScheme(.light)
    }

    #Preview("Events dark") {
        EventsPreview(store: PreviewFixtures.store())
            .preferredColorScheme(.dark)
    }
#endif
