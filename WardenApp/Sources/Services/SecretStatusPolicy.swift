import Security

/// Pure decisions about Keychain `OSStatus` values, kept out of the (coverage-excluded) Keychain file so they are
/// tested.
enum SecretStatusPolicy {
    enum Step: Equatable {
        case done
        case add
        /// The existing item is unreadable (stale legacy ACL after a rebuild): replace it.
        case deleteThenAdd
        case retryUpdateOnce
        case fail
    }

    static func nextStep(afterUpdate status: OSStatus) -> Step {
        switch status {
        case errSecSuccess: .done
        case errSecItemNotFound: .add
        case _ where requiresReentry(status): .deleteThenAdd
        case errSecDuplicateItem: .retryUpdateOnce
        default: .fail
        }
    }

    /// Statuses meaning the stored token cannot be accessed and the user must re-enter it.
    static func requiresReentry(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed || status == errSecUserCanceled
    }
}
