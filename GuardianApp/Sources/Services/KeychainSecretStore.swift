import Foundation
import Security

enum KeychainError: Error, Equatable {
    /// The item exists but cannot be read now (legacy ACL bound to an older code signature, or no UI allowed):
    /// the user must re-enter the token.
    case reenterToken(OSStatus)
    case failure(OSStatus)

    static func from(_ status: OSStatus) -> KeychainError {
        SecretStatusPolicy.requiresReentry(status) ? .reenterToken(status) : .failure(status)
    }
}

/// Generic-password Keychain item holding the agent token. The Keychain C API is synchronous and
/// called directly. Errors carry only an `OSStatus`, never the token. Excluded from the coverage gate.
///
/// Uses the legacy file keychain (`kSecUseDataProtectionKeychain: false`): the data-protection keychain needs
/// team-prefixed entitlements that an ad-hoc build lacks. Consequence: legacy ACLs are bound to the code signature,
/// so after a rebuild (new cdhash) reads may prompt or fail (errSecAuthFailed / errSecInteractionNotAllowed);
/// those map to `KeychainError.reenterToken`. Saving then deletes the unreadable item and adds a fresh one, so
/// re-entering the token always recovers. No `kSecAttrAccessible` is passed: the legacy file keychain has no
/// accessibility classes (the item is unlocked with the login keychain) and the attribute can fail with errSecParam.
/// `kSecAttrSynchronizable` stays unset.
///
/// Reads stay interactive: there is no warning-free way to suppress the legacy keychain's ACL dialog.
/// `kSecUseAuthenticationUIFail` is deprecated; its replacement (`kSecUseAuthenticationContext` with
/// `LAContext.interactionNotAllowed`) and `kSecUseNoAuthenticationUI` apply only to data-protection keychain items
/// (SecItem.h: "Legacy keychain items will still activate UI if needed"); `kSecUseAuthenticationUISkip` would turn
/// an unreadable item into errSecItemNotFound (losing the re-enter hint), and `SecKeychainSetUserInteractionAllowed`
/// is deprecated and process-wide. Callers wrap this store in `CachedSecretStore`, which reads once and retries a
/// failed read at most once per minute, so a dialog cannot loop with the sync tick.
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

    /// Decisions live in `SecretStatusPolicy` (tested); this method only executes them.
    func saveToken(_ token: String) async throws {
        let data = Data(token.utf8)
        let updateStatus = update(data)
        switch SecretStatusPolicy.nextStep(afterUpdate: updateStatus) {
        case .done:
            return
        case .add:
            try add(data)
        case .deleteThenAdd:
            let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw KeychainError.from(deleteStatus)
            }
            try add(data)
        case .retryUpdateOnce:
            let retry = update(data)
            guard retry == errSecSuccess else {
                throw KeychainError.from(retry)
            }
        case .fail:
            throw KeychainError.from(updateStatus)
        }
    }

    private func update(_ data: Data) -> OSStatus {
        SecItemUpdate(baseQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
    }

    private func add(_ data: Data) throws {
        var attributes = baseQuery
        attributes[kSecValueData] = data
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Lost a race with another writer: the item exists now, so update it once.
            status = update(data)
        }
        guard status == errSecSuccess else {
            throw KeychainError.from(status)
        }
    }

    func deleteToken() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status)
        }
    }
}
