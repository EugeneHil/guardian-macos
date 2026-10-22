import SwiftUI

enum WDButtonStyle {
    case primary, secondary
}

struct WDButton: View {
    let title: String
    let style: WDButtonStyle
    let action: @MainActor () -> Void

    init(_ title: String, style: WDButtonStyle = .primary, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Typography.body.weight(.medium))
                .foregroundStyle(style == .primary ? Tokens.Palette.onAccent : Tokens.Palette.textPrimary)
                .padding(.horizontal, Tokens.Spacing.lg)
                .padding(.vertical, Tokens.Spacing.sm)
                .background(
                    style == .primary ? Tokens.Palette.accent : Tokens.Palette.surface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .stroke(style == .primary ? Color.clear : Tokens.Palette.border)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview("WDButton light") {
    HStack {
        WDButton("Install") {}
        WDButton("Cancel", style: .secondary) {}
    }
    .padding(Tokens.Spacing.lg)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.light)
}

#Preview("WDButton dark") {
    HStack {
        WDButton("Install") {}
        WDButton("Cancel", style: .secondary) {}
    }
    .padding(Tokens.Spacing.lg)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.dark)
}
