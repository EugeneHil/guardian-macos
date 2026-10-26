import Foundation

actor InMemorySecretStore: SecretStoring {
    private var stored: String?

    init(token: String? = nil) {
        stored = token
    }

    func token() async throws -> String? {
        stored
    }

    func saveToken(_ token: String) async throws {
        stored = token
    }

    func deleteToken() async throws {
        stored = nil
    }
}
