import Foundation
import Security

enum KeychainError: Error, Equatable {
    /// The item exists but cannot be read now (legacy ACL bound to an older code signature, or no UI allowed):
    /// the user must re-enter the token.
    case reenterToken(OSStatus)
    case failure(OSStatus)

    static func from(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            .reenterToken(status)
        default:
            .failure(status)
        }
    }
}

/// Generic-password Keychain item holding the agent token. The Keychain C API is synchronous and
/// called directly. Errors carry only an `OSStatus`, never the token. Excluded from the coverage gate.
///
/// Uses the legacy file keychain (`kSecUseDataProtectionKeychain: false`): the data-protection keychain needs
/// team-prefixed entitlements that an ad-hoc build lacks. Consequence: legacy ACLs are bound to the code signature,
/// so after a rebuild (new cdhash) reads may prompt or fail (errSecAuthFailed / errSecInteractionNotAllowed);
/// those map to `KeychainError.reenterToken` and the user re-enters the token. The accessibility attribute
/// (`AfterFirstUnlock`, so the background agent can read while the screen is locked) may be ignored by the
/// legacy keychain.
final class KeychainSecretStore: SecretStoring {
    static let defaultService = "\(BundleIDs.app).agent-token"
    private static let account = "agent-token"

    private let service: String

    init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account,
            kSecUseDataProtectionKeychain: false,
        ]
    }

    func token() async throws -> String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.from(status)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) async throws {
        let data = Data(token.utf8)
        if try update(data) {
            return
        }
        var attributes = baseQuery
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        // Lost a race with another writer: the item exists now, so update it once.
        guard addStatus == errSecDuplicateItem, try update(data) else {
            throw KeychainError.from(addStatus)
        }
    }

    /// Returns false when the item does not exist yet.
    private func update(_ data: Data) throws -> Bool {
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status == errSecItemNotFound {
            return false
        }
        throw KeychainError.from(status)
    }

    func deleteToken() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status)
        }
    }
}
