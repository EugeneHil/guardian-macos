import XCTest

final class ExtensionStateTests: XCTestCase {
    func testFinishedWithoutRebootIsActive() {
        XCTAssertEqual(ExtensionState.reduce(.awaitingApproval, event: .finished(rebootNeeded: false)), .active)
    }

    func testFinishedNeedingRebootAsksForRestart() {
        XCTAssertEqual(
            ExtensionState.reduce(.unknown, event: .finished(rebootNeeded: true)),
            .failed("Restart the Mac to finish installing the extension.")
        )
    }

    func testNeedsApprovalIsAwaitingApproval() {
        XCTAssertEqual(ExtensionState.reduce(.notInstalled, event: .needsApproval), .awaitingApproval)
    }

    func testFailureCode4MapsToReadableMessage() {
        XCTAssertEqual(
            ExtensionState.reduce(.unknown, event: .failed(code: 4)),
            .failed("The extension was not found in the app bundle (its bundle must be named after its identifier).")
        )
    }

    func testFailureCode9MapsToUsageDescriptionMessage() {
        XCTAssertEqual(
            ExtensionState.reduce(.unknown, event: .failed(code: 9)),
            .failed("The extension failed validation: check NSSystemExtensionUsageDescription in its Info.plist.")
        )
    }

    func testOtherFailureCodesAreNamed() {
        XCTAssertEqual(
            ExtensionState.reduce(.active, event: .failed(code: 42)),
            .failed("The system extension request failed (code 42).")
        )
    }

    func testDeactivationFinishedIsNotInstalled() {
        XCTAssertEqual(ExtensionState.reduce(.active, event: .deactivated), .notInstalled)
    }

    func testPropertiesInactiveIsNotInstalled() {
        XCTAssertEqual(ExtensionState.reduce(.unknown, event: .propertiesActive(false)), .notInstalled)
    }

    func testPropertiesActiveIsActive() {
        XCTAssertEqual(ExtensionState.reduce(.unknown, event: .propertiesActive(true)), .active)
    }

    func testFinishedRequestMapsByKind() {
        XCTAssertEqual(
            ExtensionRequestEvent.finished(.activation, rebootNeeded: false), .finished(rebootNeeded: false)
        )
        XCTAssertEqual(ExtensionRequestEvent.finished(.activation, rebootNeeded: true), .finished(rebootNeeded: true))
        XCTAssertEqual(ExtensionRequestEvent.finished(.deactivation, rebootNeeded: false), .deactivated)
        XCTAssertNil(
            ExtensionRequestEvent.finished(.properties, rebootNeeded: false),
            "only foundProperties decides the state of a properties request"
        )
    }
}
