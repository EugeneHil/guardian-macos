import Foundation
import Observation

/// Presentation logic for the settings window. Never exposes or logs the token.
@MainActor @Observable
final class SettingsViewModel {
    var serverURLText: String {
        didSet { saveFailure = nil }
    }

    var pinText: String {
        didSet { saveFailure = nil }
    }

    var tokenText = "" {
        didSet { saveFailure = nil }
    }

    private var saveFailure: String?

    @ObservationIgnored private let store: AppStateStore
    @ObservationIgnored private let settings: any SettingsStoring
    @ObservationIgnored private let secrets: any SecretStoring
    @ObservationIgnored private let extensionManager: any ExtensionManaging
    @ObservationIgnored private let resumeSync: @Sendable () async -> Void
    @ObservationIgnored private let resumeUploader: @Sendable () async -> Void

    init(
        store: AppStateStore, settings: any SettingsStoring, secrets: any SecretStoring,
        extensionManager: any ExtensionManaging, resumeSync: @escaping @Sendable () async -> Void,
        resumeUploader: @escaping @Sendable () async -> Void
    ) {
        self.store = store
        self.settings = settings
        self.secrets = secrets
        self.extensionManager = extensionManager
        self.resumeSync = resumeSync
        self.resumeUploader = resumeUploader
        let loaded = settings.load()
        serverURLText = loaded.serverURL?.absoluteString ?? ""
        pinText = loaded.spkiPin
    }

    /// User-facing validation messages. Never include field values.
    var issues: [String] {
        var messages = validation.map(Self.message(for:))
        if let saveFailure {
            messages.append(saveFailure)
        }
        return messages
    }

    var canSave: Bool {
        validation.isEmpty
    }

    var extensionStateText: String {
        switch store.extensionState {
        case .unknown: "Checking..."
        case .notInstalled: "Not installed"
        case .awaitingApproval: "Awaiting approval in System Settings"
        case .active: "Active"
        case let .failed(message): message
        }
    }

    func save() async {
        guard canSave, let url = URL(string: trimmedURL) else { return }
        do {
            try await secrets.saveToken(tokenText)
        } catch {
            saveFailure = "Could not store the agent token in the Keychain."
            return
        }
        settings.save(AgentSettings(serverURL: url, spkiPin: trimmedPin))
        tokenText = ""
        await resumeSync()
        await resumeUploader()
    }

    func installTapped() async {
        await extensionManager.install()
    }

    func uninstallTapped() async {
        await extensionManager.uninstall()
    }

    private var trimmedURL: String {
        serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPin: String {
        pinText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validation: [SettingsIssue] {
        AgentSettings.validate(urlText: trimmedURL, pin: trimmedPin, token: tokenText)
    }

    private static func message(for issue: SettingsIssue) -> String {
        switch issue {
        case .invalidURL: "Enter a valid server address, for example https://warden.example.com."
        case .notHTTPS: "The server address must use https."
        case .invalidPin: "The certificate pin must be a base64 SHA-256 digest."
        case .invalidToken: "The agent token format is invalid."
        }
    }
}
