import Foundation
import Observation

/// Presentation logic for the settings window. Never exposes or logs the token.
@MainActor @Observable
final class SettingsViewModel {
    var serverURLText: String {
        didSet { fieldChanged() }
    }

    var pinText: String {
        didSet { fieldChanged() }
    }

    var tokenText = "" {
        didSet { fieldChanged() }
    }

    private(set) var hasStoredToken = false
    private var saveFailure: String?
    /// Validation stays quiet on the untouched first-run form until a field is edited or Save is attempted.
    private var showsValidation = false
    @ObservationIgnored private var isSaving = false

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
        var messages = showsValidation ? validation.map(Self.message(for:)) : []
        if let saveFailure {
            messages.append(saveFailure)
        }
        return messages
    }

    var canSave: Bool {
        fieldIssues.isEmpty && tokenIsAcceptable
    }

    /// Reads whether a token is already stored, so saving does not force retyping it.
    func loadStoredToken() async {
        hasStoredToken = await (try? secrets.token()) != nil
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

    /// Shown when the extension is active but unreachable (see `SetupHints`).
    var fullDiskAccessHint: String? {
        SetupHints.fullDiskAccess(sync: store.syncState, extensionState: store.extensionState)
    }

    func save() async {
        showsValidation = true
        guard !isSaving, canSave, let url = URL(string: trimmedURL) else { return }
        isSaving = true
        defer { isSaving = false }
        let savedToken = tokenText
        if !savedToken.isEmpty {
            do {
                try await secrets.saveToken(savedToken)
            } catch {
                saveFailure = "Could not store the agent token in the Keychain."
                return
            }
            hasStoredToken = true
        }
        settings.save(AgentSettings(serverURL: url, spkiPin: trimmedPin))
        if tokenText == savedToken {
            tokenText = ""
        }
        await resumeSync()
        await resumeUploader()
    }

    func installTapped() async {
        await extensionManager.install()
    }

    func uninstallTapped() async {
        await extensionManager.uninstall()
    }

    private func fieldChanged() {
        saveFailure = nil
        showsValidation = true
    }

    private var trimmedURL: String {
        serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPin: String {
        pinText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fieldIssues: [SettingsIssue] {
        AgentSettings.validate(urlText: trimmedURL, pin: trimmedPin, token: tokenText).filter { $0 != .invalidToken }
    }

    private var tokenIsAcceptable: Bool {
        tokenText.isEmpty ? hasStoredToken : AgentSettings.isValidToken(tokenText)
    }

    private var validation: [SettingsIssue] {
        var result = fieldIssues
        if !tokenText.isEmpty, !AgentSettings.isValidToken(tokenText) {
            result.append(.invalidToken)
        }
        return result
    }

    private static func message(for issue: SettingsIssue) -> String {
        switch issue {
        case .invalidURL: "Enter a valid server address, for example https://guardian.example.com."
        case .notHTTPS: "The server address must use https."
        case .invalidPin: "The certificate pin must be a base64 SHA-256 digest."
        case .invalidToken: "The agent token format is invalid."
        }
    }
}
