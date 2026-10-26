import Foundation
import XCTest

/// Guards ADR-0003: ATS rejects a self-signed server certificate even when the pinning delegate
/// accepts it, so the app must ship with NSAllowsArbitraryLoads. The unit-test bundle is not hosted,
/// so the plist Tuist generates for GuardianApp is read from Derived/InfoPlists.
final class AppInfoPlistTests: XCTestCase {
    private func appInfoPlist() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Derived/InfoPlists/GuardianApp-Info.plist")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testAppTransportSecurityAllowsArbitraryLoadsForPinnedTransport() throws {
        let plist = try appInfoPlist()
        let ats = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
    }
}
