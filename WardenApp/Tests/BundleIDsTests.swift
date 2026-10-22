import XCTest

final class AppBundleIDsTests: XCTestCase {
    func testAppGroupMatchesAppIdentifier() {
        XCTAssertEqual(BundleIDs.appGroup, BundleIDs.app)
        XCTAssertEqual(BundleIDs.app, "io.github.eugenehil.warden")
    }
}
