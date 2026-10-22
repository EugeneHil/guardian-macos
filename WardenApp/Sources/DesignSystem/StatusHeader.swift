import SwiftUI

struct StatusHeader: View {
    let title: String
    let isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.textPrimary)
            Spacer()
            Badge(isOn ? "ON" : "OFF", kind: isOn ? .ok : .neutral)
        }
        .padding(Tokens.Spacing.md)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .accessibilityElement(children: .combine)
    }
}

#Preview("StatusHeader light") {
    VStack {
        StatusHeader(title: "Protection", isOn: true)
        StatusHeader(title: "Protection", isOn: false)
    }
    .padding(Tokens.Spacing.lg)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.light)
}

#Preview("StatusHeader dark") {
    VStack {
        StatusHeader(title: "Protection", isOn: true)
        StatusHeader(title: "Protection", isOn: false)
    }
    .padding(Tokens.Spacing.lg)
    .background(Tokens.Palette.background)
    .preferredColorScheme(.dark)
}
