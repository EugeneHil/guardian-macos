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
        if !isCanonicalPin(pin) {
            issues.append(.invalidPin)
        }
        if !isValidToken(token) {
            issues.append(.invalidToken)
        }
        return issues
    }

    /// Base64 of exactly 32 bytes whose canonical re-encoding is identical (no lenient padding bits).
    static func isCanonicalPin(_ pin: String) -> Bool {
        guard let data = Data(base64Encoded: pin), data.count == SPKIPin.digestLength else {
            return false
        }
        return data.base64EncodedString() == pin
    }

    static func urlIssue(_ text: String) -> SettingsIssue? {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard text.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
              let url = URL(string: text), let scheme = url.scheme, let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let rawPath = URLComponents(string: text)?.path, rawPath.isEmpty || rawPath == "/",
              !text.contains("?"), !text.contains("#")
        else {
            return .invalidURL
        }
        return scheme.lowercased() == "https" ? nil : .notHTTPS
    }

    /// `^wdn_[0-9a-f]{64}$`, checked byte-wise so a trailing newline cannot slip through.
    static func isValidToken(_ token: String) -> Bool {
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

/// Non-secret settings in `UserDefaults` (the token lives in the Keychain). The default is `.standard`, which
/// is the app's own bundle-id domain; `UserDefaults(suiteName:)` must never be given the app's own bundle id.
/// `@unchecked Sendable`: UserDefaults is documented as thread-safe but not annotated Sendable by the SDK.
final class UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    private static let urlKey = "serverURL"
    private static let pinKey = "spkiPin"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var usesStandardDefaults: Bool {
        defaults === UserDefaults.standard
    }

    func load() -> AgentSettings {
        let url = defaults.string(forKey: Self.urlKey).flatMap { URL(string: $0) }
        return AgentSettings(serverURL: url, spkiPin: defaults.string(forKey: Self.pinKey) ?? "")
    }

    func save(_ settings: AgentSettings) {
        defaults.set(settings.serverURL?.absoluteString, forKey: Self.urlKey)
        defaults.set(settings.spkiPin, forKey: Self.pinKey)
    }
}
