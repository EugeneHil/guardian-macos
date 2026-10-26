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
        let model = await makeModel(sync: .unreachable(lastVersion: 2, reason: .transport), ext: .active)
        XCTAssertEqual(model.policyLine, "Policy v2 · server unreachable")
        XCTAssertTrue(model.isProtectionActive)
    }

    func testPolicyLinePinMismatchWithVersion() async {
        let model = await makeModel(sync: .unreachable(lastVersion: 2, reason: .pinMismatch), ext: .active)
        XCTAssertEqual(model.policyLine, "Policy v2 · certificate pin mismatch")
        XCTAssertTrue(model.isProtectionActive)
    }

    func testPolicyLinePinMismatchWithoutVersion() async {
        let model = await makeModel(sync: .unreachable(lastVersion: nil, reason: .pinMismatch), ext: .active)
        XCTAssertEqual(model.policyLine, "Certificate pin mismatch")
        XCTAssertFalse(model.isProtectionActive)
    }

    func testPolicyLineOtherReasonsStayServerUnreachable() async {
        for reason in [UnreachableReason.transport, .serverError, .other] {
            let model = await makeModel(sync: .unreachable(lastVersion: 2, reason: reason), ext: .active)
            XCTAssertEqual(model.policyLine, "Policy v2 · server unreachable")
        }
    }

    func testPolicyLineWithoutPolicy() async {
        let none = await makeModel(sync: .unreachable(lastVersion: nil, reason: .transport), ext: .active)
        XCTAssertEqual(none.policyLine, "No policy yet")
        XCTAssertFalse(none.isProtectionActive)
        let idle = await makeModel(sync: .idle, ext: .active)
        XCTAssertEqual(idle.policyLine, "No policy yet")
    }

    func testUnauthorizedShowsCredentialHint() async {
        let model = await makeModel(sync: .unauthorized, ext: .active)
        XCTAssertEqual(model.policyLine, "Check agent token")
    }

    private func makeModel(syncs: [SyncState], ext: ExtensionState) async -> PopoverViewModel {
        let harness = StoreHarness()
        let store = harness.makeStore()
        for sync in syncs {
            harness.sync.continuation.yield(sync)
        }
        harness.ext.continuation.yield(ext)
        await harness.settle(store)
        return PopoverViewModel(
            store: store, syncNow: {}, openSettings: {}, openEvents: {}, now: { EventFixture.now },
            home: "/Users/eugene"
        )
    }

    func testStaysActiveAfterThrottle() async {
        let model = await makeModel(
            syncs: [.synced(version: 2, at: now), .throttled(until: now.addingTimeInterval(30))], ext: .active
        )
        XCTAssertTrue(model.isProtectionActive)
        XCTAssertEqual(model.statusTitle, "Protection active")
    }

    func testStaysActiveAfterUnauthorizedButHintRemains() async {
        let model = await makeModel(syncs: [.synced(version: 2, at: now), .unauthorized], ext: .active)
        XCTAssertTrue(model.isProtectionActive)
        XCTAssertEqual(model.policyLine, "Check agent token")
    }

    func testOffWhenNeverSyncedAndUnauthorized() async {
        let model = await makeModel(syncs: [.unauthorized], ext: .active)
        XCTAssertFalse(model.isProtectionActive)
    }

    func testExtensionUnavailableNeverCountsAsPolicy() async {
        let model = await makeModel(syncs: [.extensionUnavailable(version: 3)], ext: .active)
        XCTAssertFalse(model.isProtectionActive)
        let afterSync = await makeModel(
            syncs: [.synced(version: 2, at: now), .extensionUnavailable(version: 3)], ext: .active
        )
        XCTAssertTrue(afterSync.isProtectionActive)
    }

    func testExtensionUnavailableWithoutVersionReadsNoPolicy() async {
        let model = await makeModel(syncs: [.extensionUnavailable(version: 0)], ext: .active)
        XCTAssertEqual(model.policyLine, "No policy yet")
    }

    func testPolicyRejectedShowsVersionOfLastAppliedPolicy() async {
        let model = await makeModel(syncs: [.policyRejected(version: 3)], ext: .active)
        XCTAssertEqual(model.policyLine, "Policy v3 · new policy rejected")
    }

    func testPolicyRejectedWithoutAppliedPolicy() async {
        let model = await makeModel(syncs: [.policyRejected(version: 0)], ext: .active)
        XCTAssertEqual(model.policyLine, "Policy rejected by extension")
    }

    func testPolicyRejectedNeverCountsAsPolicy() async {
        let model = await makeModel(syncs: [.policyRejected(version: 3)], ext: .active)
        XCTAssertFalse(model.isProtectionActive)
        let afterSync = await makeModel(
            syncs: [.synced(version: 2, at: now), .policyRejected(version: 2)], ext: .active
        )
        XCTAssertTrue(afterSync.isProtectionActive)
    }

    func testNoFullDiskAccessHintOnPolicyRejection() async {
        let model = await makeModel(sync: .policyRejected(version: 2), ext: .active)
        XCTAssertNil(model.fullDiskAccessHint)
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

    func testFullDiskAccessHintWhenActiveExtensionIsUnreachable() async {
        let model = await makeModel(sync: .extensionUnavailable(version: 0), ext: .active)
        XCTAssertEqual(model.fullDiskAccessHint, "Open System Settings → Privacy & Security → Full Disk Access")
    }

    func testNoFullDiskAccessHintWhenSyncedOrNotInstalled() async {
        let synced = await makeModel(sync: .synced(version: 2, at: now), ext: .active)
        XCTAssertNil(synced.fullDiskAccessHint)
        let notInstalled = await makeModel(sync: .extensionUnavailable(version: 2), ext: .notInstalled)
        XCTAssertNil(notInstalled.fullDiskAccessHint)
    }

    func testUnreachableWithExtensionVersionShowsProtectionActive() async {
        let model = await makeModel(syncs: [.unreachable(lastVersion: 3, reason: .serverError)], ext: .active)
        XCTAssertTrue(model.isProtectionActive)
        XCTAssertEqual(model.statusTitle, "Protection active")
        XCTAssertEqual(model.policyLine, "Policy v3 · server unreachable")
    }
}
