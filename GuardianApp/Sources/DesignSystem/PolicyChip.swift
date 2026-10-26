import SwiftUI

struct PolicyChip: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Tokens.Typography.mono)
            .foregroundStyle(Tokens.Palette.textPrimary)
            .padding(.horizontal, Tokens.Spacing.sm)
            .padding(.vertical, Tokens.Spacing.xs)
            .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).stroke(Tokens.Palette.border))
    }
}

#Preview("PolicyChip light") {
    HStack {
        PolicyChip("*.pem")
        PolicyChip("~/.ssh/**")
    }
    .padding(Tokens.Spacing.lg)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.light)
}

#Preview("PolicyChip dark") {
    HStack {
        PolicyChip("*.pem")
        PolicyChip("~/.ssh/**")
    }
    .padding(Tokens.Spacing.lg)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.dark)
}
