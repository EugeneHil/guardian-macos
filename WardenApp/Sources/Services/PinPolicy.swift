import Foundation

/// The TLS trust decision, kept pure so it is tested without a network. There is no CA fallback: only a server-trust
/// challenge whose leaf key hashes to the configured SPKI pin is accepted.
enum PinPolicy {
    enum Decision: Equatable {
        /// Use the presented trust as the credential.
        case accept
        /// Server-trust challenge with a missing or different pin: cancel and report `pinMismatch`.
        case rejectPin
        /// Any other authentication method: cancel (the agent never answers Basic, client-certificate, ...).
        case cancel
    }

    static func decide(authenticationMethod: String, leafPin: String?, expectedPin: String) -> Decision {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return .cancel
        }
        guard let leafPin, !expectedPin.isEmpty, SPKIPin.matches(leafPin, expectedPin) else {
            return .rejectPin
        }
        return .accept
    }
}
