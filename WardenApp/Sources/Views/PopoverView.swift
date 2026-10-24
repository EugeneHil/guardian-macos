import SwiftUI

/// Menu bar popover (mockup A "Native Calm"): status, policy line, recent events and the window links.
struct PopoverView: View {
    let model: PopoverViewModel

    private static let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            StatusHeader(title: model.statusTitle, isOn: model.isProtectionActive)
            policyRow
            if let hint = model.fullDiskAccessHint {
                Text(hint)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            divider
            recentEvents
            divider
            footer
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: Self.width)
        .background(Tokens.Palette.background)
    }

    private var policyRow: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Text(model.policyLine)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Tokens.Spacing.sm)
            WDButton("Sync now", style: .secondary) {
                Task { await model.syncNowTapped() }
            }
        }
    }

    @ViewBuilder
    private var recentEvents: some View {
        Text("Recent events")
            .font(Tokens.Typography.caption.weight(.semibold))
            .foregroundStyle(Tokens.Palette.textSecondary)
        if model.recentRows.isEmpty {
            Text("No events yet")
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .padding(.vertical, Tokens.Spacing.sm)
        } else {
            VStack(spacing: 0) {
                ForEach(model.recentRows) { row in
                    EventRow(model: row)
                }
            }
            .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        }
    }

    private var footer: some View {
        HStack {
            WDButton("All events…", style: .secondary) { model.openEventsTapped() }
            Spacer()
            WDButton("Settings", style: .secondary) { model.openSettingsTapped() }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Tokens.Palette.border)
            .frame(height: 1)
    }
}

#if DEBUG
    private struct PopoverPreview: View {
        let store: AppStateStore

        var body: some View {
            PopoverView(model: PreviewFixtures.popover(store))
                .task { await store.run() }
        }
    }

    #Preview("Popover light") {
        PopoverPreview(store: PreviewFixtures.store())
            .preferredColorScheme(.light)
    }

    #Preview("Popover dark") {
        PopoverPreview(store: PreviewFixtures.store())
            .preferredColorScheme(.dark)
    }

    #Preview("Popover not installed") {
        PopoverPreview(store: PreviewFixtures.store(sync: .idle, extensionState: .notInstalled, events: []))
            .preferredColorScheme(.light)
    }

    #Preview("Popover needs Full Disk Access") {
        PopoverPreview(store: PreviewFixtures.store(sync: .extensionUnavailable(version: 2), events: []))
            .preferredColorScheme(.dark)
    }
#endif
