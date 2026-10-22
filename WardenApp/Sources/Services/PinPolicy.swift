import Foundation

/// The TLS trust decision, kept pure so it is tested without a network. There is no CA fallback: only a server-trust
/// challenge whose leaf key hashes to the configured SPKI pin is accepted.
enum PinPolicy {
    enum Decision: Equatable {
        /// Use the presented trust as the credential.
        case accept
        /// Server-trust challenge with a missing or different pin: cancel and report `pinMismatch`.
        case rejectPin
        /// Any other authentication method: reject the protection space (the agent never answers Basic,
        /// client-certificate, ...), so a 401 arrives as an HTTP response.
        case rejectProtectionSpace
    }

    static func decide(authenticationMethod: String, leafPin: String?, expectedPin: String) -> Decision {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return .rejectProtectionSpace
        }
        guard let leafPin, !expectedPin.isEmpty, SPKIPin.matches(leafPin, expectedPin) else {
            return .rejectPin
        }
        return .accept
    }
}
