import SwiftUI

enum BadgeKind: Equatable {
    // swiftlint:disable:next identifier_name
    case blocked, ok, neutral
}

struct Badge: View {
    let text: String
    let kind: BadgeKind

    init(_ text: String, kind: BadgeKind) {
        self.text = text
        self.kind = kind
    }

    private var color: Color {
        switch kind {
        case .blocked: Tokens.Palette.danger
        case .ok: Tokens.Palette.success
        case .neutral: Tokens.Palette.textSecondary
        }
    }

    var body: some View {
        Text(text)
            .font(Tokens.Typography.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, Tokens.Spacing.xs)
            .background(color.opacity(0.14), in: Capsule())
    }
}

#Preview("Badge light") {
    HStack {
        Badge("Blocked", kind: .blocked)
        Badge("Allowed", kind: .ok)
        Badge("Off", kind: .neutral)
    }
    .padding(Tokens.Spacing.lg)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.light)
}

#Preview("Badge dark") {
    HStack {
        Badge("Blocked", kind: .blocked)
        Badge("Allowed", kind: .ok)
        Badge("Off", kind: .neutral)
    }
    .padding(Tokens.Spacing.lg)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.dark)
}
