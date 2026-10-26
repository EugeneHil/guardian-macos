import Foundation
import XCTest

final class BundleIDsTests: XCTestCase {
    func testBundleIDsAreConsistent() throws {
        XCTAssertEqual(BundleIDs.ext, BundleIDs.app + ".ext")
        XCTAssertTrue(BundleIDs.machService.hasPrefix(BundleIDs.appGroup))
        XCTAssertEqual(BundleIDs.machService, "io.github.eugenehil.guardian.ext")
        XCTAssertEqual(DataPaths.policyFile, "/Library/Application Support/Guardian/policy.json")

        // #filePath = <root>/DlpExtension/Tests/BundleIDsTests.swift; Info.plist lives two levels up.
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["NSEndpointSecurityMachServiceName"] as? String, BundleIDs.machService)
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "SYSX")
    }
}
