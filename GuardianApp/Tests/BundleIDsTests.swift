import XCTest

final class AppBundleIDsTests: XCTestCase {
    func testAppGroupMatchesAppIdentifier() {
        XCTAssertEqual(BundleIDs.appGroup, BundleIDs.app)
        XCTAssertEqual(BundleIDs.app, "io.github.eugenehil.guardian")
        XCTAssertEqual(BundleIDs.ext, "io.github.eugenehil.guardian.ext")
        XCTAssertEqual(BundleIDs.machService, "io.github.eugenehil.guardian.ext")
        XCTAssertEqual(KeychainSecretStore.defaultService, "io.github.eugenehil.guardian.agent-token")
        XCTAssertEqual(GuardianXPCError.domain, "io.github.eugenehil.guardian")
        XCTAssertEqual(GuardianXPCError.validationErrorsKey, "GuardianValidationErrors")
    }
}
