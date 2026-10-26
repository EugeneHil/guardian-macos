import CoreBridge
import Foundation
import XCTest

final class PolicyHolderTests: XCTestCase {
    private func allows(_ holder: PolicyHolder, _ path: String) -> Bool {
        var copy = path
        return copy.withUTF8 { holder.fastPathAllows(UnsafeRawBufferPointer($0)) }
    }

    private func policy() throws -> GDPolicy {
        try GDPolicy(json: PolicyFixtures.policy(version: 7))
    }

    func testAllowsUntilPolicyLoaded() {
        let holder = PolicyHolder()
        XCTAssertNil(holder.engine())
        XCTAssertEqual(holder.version, 0)
        XCTAssertTrue(allows(holder, "/Users/a/.secrets"))
    }

    func testProtectedPathIsNotFastPath() throws {
        let holder = PolicyHolder()
        try holder.set(policy: policy())
        XCTAssertEqual(holder.version, 7)
        XCTAssertFalse(allows(holder, "/Users/a/.secrets"))
    }

    func testUnrelatedPathIsFastPath() throws {
        let holder = PolicyHolder()
        try holder.set(policy: policy())
        XCTAssertTrue(allows(holder, "/Users/a/notes.txt"))
    }

    private func decision(_ holder: PolicyHolder, _ path: String) -> (allows: Bool, generation: UInt64) {
        var copy = path
        return copy.withUTF8 { holder.fastPathDecision(UnsafeRawBufferPointer($0)) }
    }

    func testGenerationStartsAtZeroAndBumpsOnSetAndClear() throws {
        let holder = PolicyHolder()
        XCTAssertEqual(holder.generation, 0)
        try holder.set(policy: policy())
        XCTAssertEqual(holder.generation, 1)
        try holder.set(policy: policy())
        XCTAssertEqual(holder.generation, 2, "re-applying the same version is still a new generation")
        holder.clear()
        XCTAssertEqual(holder.generation, 3)
        holder.clear()
        XCTAssertEqual(holder.generation, 4)
    }

    func testFastPathDecisionReportsVerdictWithItsGeneration() throws {
        let holder = PolicyHolder()
        let empty = decision(holder, "/Users/a/.secrets")
        XCTAssertTrue(empty.allows)
        XCTAssertEqual(empty.generation, 0)

        try holder.set(policy: policy())
        let protected = decision(holder, "/Users/a/.secrets")
        XCTAssertFalse(protected.allows)
        XCTAssertEqual(protected.generation, 1)
        let unrelated = decision(holder, "/Users/a/notes.txt")
        XCTAssertTrue(unrelated.allows)
        XCTAssertEqual(unrelated.generation, 1)

        holder.clear()
        let cleared = decision(holder, "/Users/a/.secrets")
        XCTAssertTrue(cleared.allows)
        XCTAssertEqual(cleared.generation, 2)
    }

    func testFastPathDecisionPairIsConsistentUnderConcurrentSwaps() async throws {
        let holder = PolicyHolder()
        let compiled = try policy()
        // Odd generations hold the policy, even ones are empty: a protected path may only be "not allowed"
        // together with an odd generation, and "allowed" only with an even one.
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for _ in 0 ..< 500 {
                    holder.set(policy: compiled)
                    holder.clear()
                }
                return true
            }
            for _ in 0 ..< 4 {
                group.addTask {
                    var consistent = true
                    for _ in 0 ..< 2000 {
                        var copy = "/Users/a/.secrets"
                        let pair = copy.withUTF8 { holder.fastPathDecision(UnsafeRawBufferPointer($0)) }
                        consistent = consistent && (pair.allows == pair.generation.isMultiple(of: 2))
                    }
                    return consistent
                }
            }
            for await consistent in group {
                XCTAssertTrue(consistent)
            }
        }
    }

    func testClearRemovesEngineAndVersion() throws {
        let holder = PolicyHolder()
        try holder.set(policy: policy())
        holder.clear()
        XCTAssertNil(holder.engine())
        XCTAssertEqual(holder.version, 0)
        XCTAssertTrue(allows(holder, "/Users/a/.secrets"))
    }
}
