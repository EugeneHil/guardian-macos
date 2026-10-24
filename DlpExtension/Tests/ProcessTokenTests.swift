import XCTest

final class ProcessTokenTests: XCTestCase {
    func testAuditTokenIsOptional() {
        let token = ProcessToken(pid: 42, pidVersion: 7)
        XCTAssertNil(token.auditToken)
    }

    func testAuditTokenTakesPartInEquality() {
        let words: [UInt32] = [1, 2, 3, 4, 5, 42, 6, 7]
        let full = ProcessToken(pid: 42, pidVersion: 7, auditToken: words)
        XCTAssertEqual(full, ProcessToken(pid: 42, pidVersion: 7, auditToken: words))
        XCTAssertNotEqual(full, ProcessToken(pid: 42, pidVersion: 7))
        XCTAssertEqual(full.auditToken, words)
    }

    func testFromAuditTokenWordsReadsPidAndPidVersion() {
        // audit_token_t layout: val[5] is the pid, val[7] the pid version.
        let token = ProcessToken(auditTokenWords: [501, 501, 20, 501, 20, 1234, 100_001, 9])
        XCTAssertEqual(token?.pid, 1234)
        XCTAssertEqual(token?.pidVersion, 9)
        XCTAssertEqual(token?.auditToken, [501, 501, 20, 501, 20, 1234, 100_001, 9])
    }

    func testFromAuditTokenWordsRejectsWrongLength() {
        XCTAssertNil(ProcessToken(auditTokenWords: [1, 2, 3]))
    }
}
