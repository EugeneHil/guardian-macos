import Foundation

enum ExtensionLinkError: Error, Equatable, Sendable {
    /// The system extension is not running, not approved or not reachable over XPC.
    case unavailable
    /// The extension refused the policy; the strings are its validation messages.
    case invalidPolicy([String])
}

/// The app's side of the app-to-extension channel (implemented over XPC).
protocol ExtensionLinking: Sendable {
    /// Installs the server policy (its body byte for byte) and returns the version the extension now enforces.
    func apply(policy: Data) async throws -> Int64
    func currentPolicyVersion() async throws -> Int64
    /// Removes and returns up to `max` buffered events, oldest first.
    func drainEvents(max: Int) async throws -> [AccessEvent]
    func liveEvents() -> AsyncStream<AccessEvent>
}
