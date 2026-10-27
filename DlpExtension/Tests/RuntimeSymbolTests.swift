import XCTest

final class RuntimeSymbolTests: XCTestCase {
    func testUnknownSymbolResolvesToNil() {
        XCTAssertNil(RuntimeSymbol.address(of: "guardian_symbol_that_does_not_exist"))
    }

    func testExistingSymbolResolves() {
        XCTAssertNotNil(RuntimeSymbol.address(of: "getpid"))
    }

    func testOptionalEndpointSecuritySymbolLookupDoesNotCrash() {
        // Present only on newer systems; either outcome is valid, the lookup itself must be safe.
        _ = RuntimeSymbol.address(of: "es_set_deadline_miss_mode")
    }
}
