import Foundation

/// Storage for the agent bearer token. Implementations must never log or embed the token in errors.
protocol SecretStoring: Sendable {
    func token() async throws -> String?
    func saveToken(_ token: String) async throws
    func deleteToken() async throws
}
