import Security
import XCTest

final class SecretStatusPolicyTests: XCTestCase {
    func testNextStepAfterUpdate() {
        let table: [(OSStatus, SecretStatusPolicy.Step)] = [
            (errSecSuccess, .done),
            (errSecItemNotFound, .add),
            (errSecAuthFailed, .deleteThenAdd),
            (errSecInteractionNotAllowed, .deleteThenAdd),
            (errSecUserCanceled, .deleteThenAdd),
            (errSecDuplicateItem, .retryUpdateOnce),
            (errSecParam, .fail),
            (errSecIO, .fail),
        ]
        for (status, step) in table {
            XCTAssertEqual(SecretStatusPolicy.nextStep(afterUpdate: status), step, "\(status)")
        }
    }

    func testReentryStatuses() {
        XCTAssertTrue(SecretStatusPolicy.requiresReentry(errSecAuthFailed))
        XCTAssertTrue(SecretStatusPolicy.requiresReentry(errSecInteractionNotAllowed))
        XCTAssertTrue(SecretStatusPolicy.requiresReentry(errSecUserCanceled))
        XCTAssertFalse(SecretStatusPolicy.requiresReentry(errSecParam))
        XCTAssertFalse(SecretStatusPolicy.requiresReentry(errSecItemNotFound))
    }
}
