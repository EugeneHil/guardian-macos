import CoreBridge
import Foundation
import XCTest

final class PolicyHolderTests: XCTestCase {
    private func allows(_ holder: PolicyHolder, _ path: String) -> Bool {
        var copy = path
        return copy.withUTF8 { holder.fastPathAllows(UnsafeRawBufferPointer($0)) }
    }

    private func engine() throws -> WDEngine {
        try WDEngine(policy: WDPolicy(json: PolicyFixtures.policy(version: 7)))
    }

    func testAllowsUntilPolicyLoaded() {
        let holder = PolicyHolder()
        XCTAssertNil(holder.engine())
        XCTAssertEqual(holder.version, 0)
        XCTAssertTrue(allows(holder, "/Users/a/.secrets"))
    }

    func testProtectedPathIsNotFastPath() throws {
        let holder = PolicyHolder()
        try holder.set(engine(), version: 7)
        XCTAssertEqual(holder.version, 7)
        XCTAssertFalse(allows(holder, "/Users/a/.secrets"))
    }

    func testUnrelatedPathIsFastPath() throws {
        let holder = PolicyHolder()
        try holder.set(engine())
        XCTAssertTrue(allows(holder, "/Users/a/notes.txt"))
    }

    func testSetNilClearsEngine() throws {
        let holder = PolicyHolder()
        try holder.set(engine(), version: 7)
        holder.set(nil)
        XCTAssertNil(holder.engine())
        XCTAssertEqual(holder.version, 0)
        XCTAssertTrue(allows(holder, "/Users/a/.secrets"))
    }
}
