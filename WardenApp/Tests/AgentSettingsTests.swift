import Foundation
import XCTest

final class AgentSettingsTests: XCTestCase {
    private let goodPin = Data(repeating: 7, count: 32).base64EncodedString()
    private let goodToken = "wdn_" + String(repeating: "a1", count: 32)

    private func issues(url: String = "https://h.test", pin: String? = nil, token: String? = nil) -> [SettingsIssue] {
        AgentSettings.validate(urlText: url, pin: pin ?? goodPin, token: token ?? goodToken)
    }

    func testValidInputHasNoIssues() {
        XCTAssertEqual(issues(), [])
    }

    func testValidatesHttpsUrl() {
        XCTAssertEqual(issues(url: "http://x"), [.notHTTPS])
        XCTAssertEqual(issues(url: "garbage"), [.invalidURL])
        XCTAssertEqual(issues(url: ""), [.invalidURL])
        XCTAssertEqual(issues(url: "https://"), [.invalidURL])
    }

    func testValidatesPin() {
        XCTAssertEqual(issues(pin: Data(repeating: 1, count: 31).base64EncodedString()), [.invalidPin])
        XCTAssertEqual(issues(pin: Data(repeating: 1, count: 33).base64EncodedString()), [.invalidPin])
        XCTAssertEqual(issues(pin: "not base64!!"), [.invalidPin])
        XCTAssertEqual(issues(pin: ""), [.invalidPin])
    }

    func testValidatesToken() {
        let hex63 = "wdn_" + String(repeating: "a", count: 63)
        let hex65 = "wdn_" + String(repeating: "a", count: 65)
        let upper = "wdn_" + String(repeating: "A", count: 64)
        let noPrefix = String(repeating: "a", count: 64)
        for bad in [hex63, hex65, upper, noPrefix, "", goodToken + "\n"] {
            XCTAssertEqual(issues(token: bad), [.invalidToken], bad)
        }
    }

    func testReportsAllIssues() {
        let all = AgentSettings.validate(urlText: "http://x", pin: "zz", token: "bad")
        XCTAssertEqual(all, [.notHTTPS, .invalidPin, .invalidToken])
    }

    func testTokenNeverAppearsInIssueDescription() {
        let secret = "wdn_SECRET-TOKEN-TEXT"
        let found = AgentSettings.validate(urlText: "https://h", pin: goodPin, token: secret)
        XCTAssertEqual(found, [.invalidToken])
        for issue in found {
            XCTAssertFalse(String(describing: issue).contains(secret))
            XCTAssertFalse(String(reflecting: issue).contains(secret))
        }
    }

    func testRejectsNonCanonicalBase64Pin() {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        let canonical = Array(goodPin)
        XCTAssertEqual(canonical[43], "=")
        guard let value = alphabet.firstIndex(of: canonical[42]) else { return XCTFail("not base64") }
        var tampered = canonical
        tampered[42] = alphabet[value | 1]
        XCTAssertNotEqual(tampered, canonical)
        XCTAssertNotNil(Data(base64Encoded: String(tampered)), "premise: Foundation is lenient")
        XCTAssertEqual(issues(pin: String(tampered)), [.invalidPin])
        XCTAssertEqual(issues(pin: goodPin + "\n"), [.invalidPin])
    }

    func testRejectsUnexpectedUrlParts() {
        let bad = ["https://user@h.test", "https://user:pw@h.test", "https://h.test?a=1", "https://h.test/?"]
            + ["https://h.test#frag", "https://h.test/api", "https://h.test//"]
        for url in bad {
            XCTAssertEqual(issues(url: url), [.invalidURL], url)
        }
    }

    func testAcceptsPlainOriginUrls() {
        for good in [
            "https://[::1]:8443/",
            "https://[::1]:8443",
            "https://h.test/",
            "https://h.test:8443",
            "HTTPS://H.test",
        ] {
            XCTAssertEqual(issues(url: good), [], good)
        }
    }

    func testUserDefaultsStoreRoundTripsAndDefaultsEmpty() throws {
        let suite = "io.github.eugenehil.warden.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), AgentSettings(serverURL: nil, spkiPin: ""))
        let settings = AgentSettings(serverURL: URL(string: "https://h:1"), spkiPin: goodPin)
        store.save(settings)
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).load(), settings)
        store.save(AgentSettings(serverURL: nil, spkiPin: ""))
        XCTAssertEqual(store.load(), AgentSettings(serverURL: nil, spkiPin: ""))
    }

    func testDefaultInitializerUsesStandardDefaultsNotOwnBundleSuite() {
        // UserDefaults(suiteName:) with the app's own bundle id is invalid; the default must be .standard.
        XCTAssertTrue(UserDefaultsSettingsStore().usesStandardDefaults)
    }
}
