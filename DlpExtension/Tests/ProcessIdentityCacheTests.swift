import XCTest

final class ProcessIdentityCacheTests: XCTestCase {
    private let token = ProcessToken(pid: 42, pidVersion: 7)
    private let identity = ProcessIdentity(path: "/bin/cat", signingId: "com.apple.cat", teamId: "")

    func testMissIsNotCached() {
        let cache = ProcessIdentityCache(clock: ManualClock())
        XCTAssertTrue(cache.lookup(token) == nil)
    }

    func testResolvedIdentityStaysCached() {
        let clock = ManualClock()
        let cache = ProcessIdentityCache(clock: clock)
        cache.store(identity, for: token)
        clock.advance(by: .seconds(3600))
        XCTAssertEqual(cache.lookup(token), .some(identity))
    }

    func testFailureIsCachedOnlyForItsTTL() {
        let clock = ManualClock()
        let cache = ProcessIdentityCache(failureTTL: .seconds(5), clock: clock)
        cache.store(nil, for: token)
        XCTAssertEqual(cache.lookup(token), .some(nil), "a fresh failure is answered from the cache")
        clock.advance(by: .milliseconds(4999))
        XCTAssertEqual(cache.lookup(token), .some(nil))
        clock.advance(by: .milliseconds(1))
        XCTAssertTrue(cache.lookup(token) == nil, "an expired failure is looked up again")
    }

    func testCapacityResetsTheCache() {
        let cache = ProcessIdentityCache(capacity: 2, clock: ManualClock())
        let other = ProcessToken(pid: 43, pidVersion: 1)
        let third = ProcessToken(pid: 44, pidVersion: 1)
        cache.store(identity, for: token)
        cache.store(identity, for: other)
        cache.store(identity, for: third)
        XCTAssertEqual(cache.lookup(third), .some(identity))
        XCTAssertLessThanOrEqual(cache.count, 2)
    }
}
