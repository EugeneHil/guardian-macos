import SwiftUI

/// Settings window: server connection (URL, token, certificate pin) and the system extension.
struct SettingsView: View {
    @Bindable var model: SettingsViewModel

    private static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            section("Server") {
                field("Server URL") {
                    TextField("Server URL", text: $model.serverURLText, prompt: Text("https://warden.example.com"))
                }
                field("Agent token") {
                    SecureField("Agent token", text: $model.tokenText, prompt: Text(tokenPrompt))
                }
                field("Certificate pin (SPKI SHA-256, base64)") {
                    TextField("Certificate pin", text: $model.pinText)
                        .font(Tokens.Typography.mono)
                }
                ForEach(model.issues, id: \.self) { issue in
                    Text(issue)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    WDButton("Save") {
                        Task { await model.save() }
                    }
                    .disabled(!model.canSave)
                    .opacity(model.canSave ? 1 : 0.5)
                }
            }
            section("System extension") {
                Text("Extension: \(model.extensionStateText)")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                if let hint = model.fullDiskAccessHint {
                    Text(hint)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Tokens.Spacing.sm) {
                    WDButton("Install extension") {
                        Task { await model.installTapped() }
                    }
                    WDButton("Uninstall extension", style: .secondary) {
                        Task { await model.uninstallTapped() }
                    }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(Tokens.Spacing.xl)
        .frame(width: Self.width)
        .background(Tokens.Palette.background)
        .task { await model.loadStoredToken() }
    }

    private var tokenPrompt: String {
        model.hasStoredToken ? "Stored in Keychain (leave empty to keep)" : "wdn_…"
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text(title)
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.textPrimary)
            content()
        }
        .padding(Tokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
    }

    private func field(_ label: String, @ViewBuilder input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(label)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
            input()
                .font(Tokens.Typography.body)
        }
    }
}

#if DEBUG
    private struct SettingsPreview: View {
        let store: AppStateStore

        var body: some View {
            SettingsView(model: PreviewFixtures.settings(store))
                .task { await store.run() }
        }
    }

    #Preview("Settings light") {
        SettingsPreview(store: PreviewFixtures.store(sync: .notConfigured, extensionState: .notInstalled))
            .preferredColorScheme(.light)
    }

    #Preview("Settings dark") {
        SettingsPreview(store: PreviewFixtures.store(sync: .extensionUnavailable(version: 2)))
            .preferredColorScheme(.dark)
    }
#endif
