import Foundation

/// A validation problem with the agent settings form. Cases carry no payload on purpose:
/// the token text must never end up in an issue, its description or any log.
enum SettingsIssue: Equatable {
    case invalidURL
    case notHTTPS
    case invalidPin
    case invalidToken
}

struct AgentSettings: Equatable, Sendable {
    var serverURL: URL?
    var spkiPin: String

    /// Returns every problem found, in the order URL, pin, token. Empty means valid.
    static func validate(urlText: String, pin: String, token: String) -> [SettingsIssue] {
        var issues: [SettingsIssue] = []
        if let issue = urlIssue(urlText) {
            issues.append(issue)
        }
        if Data(base64Encoded: pin)?.count != SPKIPin.digestLength {
            issues.append(.invalidPin)
        }
        if !isValidToken(token) {
            issues.append(.invalidToken)
        }
        return issues
    }

    private static func urlIssue(_ text: String) -> SettingsIssue? {
        guard let url = URL(string: text), let scheme = url.scheme, let host = url.host, !host.isEmpty else {
            return .invalidURL
        }
        return scheme.lowercased() == "https" ? nil : .notHTTPS
    }

    /// `^wdn_[0-9a-f]{64}$`, checked byte-wise so a trailing newline cannot slip through.
    private static func isValidToken(_ token: String) -> Bool {
        let prefix = Array("wdn_".utf8)
        let bytes = Array(token.utf8)
        guard bytes.count == prefix.count + 64, bytes.starts(with: prefix) else {
            return false
        }
        return bytes.dropFirst(prefix.count).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

protocol SettingsStoring: Sendable {
    func load() -> AgentSettings
    func save(_ settings: AgentSettings)
}

/// Non-secret settings in the app's `UserDefaults` suite (the token lives in the Keychain).
final class UserDefaultsSettingsStore: SettingsStoring {
    static let defaultSuiteName = BundleIDs.app
    private static let urlKey = "serverURL"
    private static let pinKey = "spkiPin"

    private let suiteName: String

    init(suiteName: String = UserDefaultsSettingsStore.defaultSuiteName) {
        self.suiteName = suiteName
    }

    func load() -> AgentSettings {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return AgentSettings(serverURL: nil, spkiPin: "")
        }
        let url = defaults.string(forKey: Self.urlKey).flatMap { URL(string: $0) }
        return AgentSettings(serverURL: url, spkiPin: defaults.string(forKey: Self.pinKey) ?? "")
    }

    func save(_ settings: AgentSettings) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return
        }
        defaults.set(settings.serverURL?.absoluteString, forKey: Self.urlKey)
        defaults.set(settings.spkiPin, forKey: Self.pinKey)
    }
}
