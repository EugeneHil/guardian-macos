import XCTest

@MainActor
final class PopoverViewModelTests: XCTestCase {
    private let now = EventFixture.now

    private func makeModel(
        sync: SyncState, ext: ExtensionState, events: [AccessEvent] = [],
        syncNow: @escaping @Sendable () async -> Void = {}
    ) async -> PopoverViewModel {
        let harness = StoreHarness()
        let store = harness.makeStore()
        harness.sync.continuation.yield(sync)
        harness.ext.continuation.yield(ext)
        for event in events {
            harness.events.continuation.yield(event)
        }
        await harness.settle(store)
        return PopoverViewModel(
            store: store, syncNow: syncNow, openSettings: {}, openEvents: {}, now: { EventFixture.now },
            home: "/Users/eugene"
        )
    }

    func testActiveWhenExtensionActiveAndPolicySynced() async {
        let model = await makeModel(sync: .synced(version: 2, at: now), ext: .active)
        XCTAssertTrue(model.isProtectionActive)
        XCTAssertEqual(model.statusTitle, "Protection active")
    }

    func testOffWhenExtensionActiveButNoPolicy() async {
        let model = await makeModel(sync: .idle, ext: .active)
        XCTAssertFalse(model.isProtectionActive)
        XCTAssertEqual(model.statusTitle, "Protection off")
    }

    func testOffWhenExtensionNotInstalled() async {
        let model = await makeModel(sync: .synced(version: 2, at: now), ext: .notInstalled)
        XCTAssertFalse(model.isProtectionActive)
        XCTAssertEqual(model.statusTitle, "Extension not installed")
    }

    func testAwaitingApprovalMessage() async {
        let model = await makeModel(sync: .idle, ext: .awaitingApproval)
        XCTAssertEqual(model.statusTitle, "Awaiting approval in System Settings")
    }

    func testPolicyLineSynced() async {
        let model = await makeModel(sync: .synced(version: 2, at: now.addingTimeInterval(-4)), ext: .active)
        XCTAssertEqual(model.policyLine, "Policy v2 · synced 4 s ago")
    }

    func testPolicyLineUnreachableKeepsVersion() async {
        let model = await makeModel(sync: .unreachable(lastVersion: 2), ext: .active)
        XCTAssertEqual(model.policyLine, "Policy v2 · server unreachable")
        XCTAssertTrue(model.isProtectionActive)
    }

    func testPolicyLineWithoutPolicy() async {
        let none = await makeModel(sync: .unreachable(lastVersion: nil), ext: .active)
        XCTAssertEqual(none.policyLine, "No policy yet")
        XCTAssertFalse(none.isProtectionActive)
        let idle = await makeModel(sync: .idle, ext: .active)
        XCTAssertEqual(idle.policyLine, "No policy yet")
    }

    func testUnauthorizedShowsCredentialHint() async {
        let model = await makeModel(sync: .unauthorized, ext: .active)
        XCTAssertEqual(model.policyLine, "Check agent token")
    }

    func testRecentRowsAreFiveNewest() async {
        let events = (0 ..< 8).map { EventFixture.make(age: Double(8 - $0)) }
        let model = await makeModel(sync: .idle, ext: .active, events: events)
        XCTAssertEqual(model.recentRows.count, 5)
        XCTAssertEqual(model.recentRows.map(\.id), events.reversed().prefix(5).map(\.id))
    }

    func testAllowEventWithRuleIsNotBlocked() async {
        let model = await makeModel(
            sync: .idle, ext: .active, events: [EventFixture.make(decision: .allow, ruleId: "r1")]
        )
        XCTAssertEqual(model.recentRows.first?.badge, .ok)
        XCTAssertEqual(model.blockedCount, 0)
    }

    func testSyncNowCallsService() async {
        let latch = CallLatch()
        let model = await makeModel(sync: .idle, ext: .active, syncNow: { latch.increment() })
        await model.syncNowTapped()
        XCTAssertEqual(latch.count, 1)
    }
}
