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

    func testUserDefaultsStoreRoundTripsAndDefaultsEmpty() {
        let suite = "io.github.eugenehil.warden.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(suiteName: suite)
        XCTAssertEqual(store.load(), AgentSettings(serverURL: nil, spkiPin: ""))
        let settings = AgentSettings(serverURL: URL(string: "https://h:1"), spkiPin: goodPin)
        store.save(settings)
        XCTAssertEqual(UserDefaultsSettingsStore(suiteName: suite).load(), settings)
        store.save(AgentSettings(serverURL: nil, spkiPin: ""))
        XCTAssertEqual(store.load(), AgentSettings(serverURL: nil, spkiPin: ""))
    }

    func testDefaultSuiteNameIsAppIdentifier() {
        XCTAssertEqual(UserDefaultsSettingsStore.defaultSuiteName, BundleIDs.app)
    }
}
