/// What the app knows about its system extension.
enum ExtensionState: Equatable, Sendable {
    case unknown
    case notInstalled
    case awaitingApproval
    case active
    case failed(String)

    /// Folds one `OSSystemExtensionRequest` outcome into the state.
    static func reduce(_: ExtensionState, event: ExtensionRequestEvent) -> ExtensionState {
        switch event {
        case .finished(rebootNeeded: false):
            .active
        case .finished(rebootNeeded: true):
            .failed("Restart the Mac to finish installing the extension.")
        case .deactivated:
            .notInstalled
        case .needsApproval:
            .awaitingApproval
        case let .propertiesActive(active):
            active ? .active : .notInstalled
        case let .failed(code):
            .failed(message(forErrorCode: code))
        }
    }

    /// Readable texts for `OSSystemExtensionError` codes (findings in ADR-0001).
    private static func message(forErrorCode code: Int) -> String {
        switch code {
        case 4:
            "The extension was not found in the app bundle (its bundle must be named after its identifier)."
        case 9:
            "The extension failed validation: check NSSystemExtensionUsageDescription in its Info.plist."
        default:
            "The system extension request failed (code \(code))."
        }
    }
}

/// Outcome of an activation, deactivation or properties request, as reported by its delegate.
enum ExtensionRequestEvent: Equatable, Sendable {
    /// An activation request finished.
    case finished(rebootNeeded: Bool)
    /// A deactivation request finished.
    case deactivated
    case failed(code: Int)
    case needsApproval
    /// A properties request found an enabled (true) or no enabled (false) extension.
    case propertiesActive(Bool)
}
