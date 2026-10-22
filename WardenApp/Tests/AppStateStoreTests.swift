import XCTest

@MainActor
final class AppStateStoreTests: XCTestCase {
    func testAppliesStreamsAndCapsEvents() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        harness.sync.continuation.yield(.synced(version: 2, at: EventFixture.now))
        harness.ext.continuation.yield(.active)
        let all = (0 ..< 600).map { EventFixture.make(age: Double(600 - $0)) }
        for event in all {
            harness.events.continuation.yield(event)
        }
        await harness.settle(store)
        XCTAssertEqual(store.syncState, .synced(version: 2, at: EventFixture.now))
        XCTAssertEqual(store.extensionState, .active)
        XCTAssertEqual(store.events.count, 500)
        XCTAssertEqual(store.events.first?.id, all.last?.id)
        XCTAssertEqual(store.events.last?.id, all[100].id)
    }

    func testRepeatedEventIDIsNotInsertedTwice() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        let event = EventFixture.make()
        harness.events.continuation.yield(event)
        harness.events.continuation.yield(EventFixture.make())
        harness.events.continuation.yield(event)
        await harness.settle(store)
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.filter { $0.id == event.id }.count, 1)
    }

    func testInitialStatesAreUnknown() {
        let store = StoreHarness().makeStore()
        XCTAssertEqual(store.syncState, .idle)
        XCTAssertEqual(store.extensionState, .unknown)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testRunEndsWhenCancelled() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        let task = Task { await store.run() }
        task.cancel()
        await task.value
    }
}
