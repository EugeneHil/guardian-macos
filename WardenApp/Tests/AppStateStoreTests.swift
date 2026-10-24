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

    func testMergesDrainedEventsWithoutDuplicates() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        let shared = EventFixture.make(age: 5)
        let liveOnly = EventFixture.make(age: 3)
        let drainedOnly = EventFixture.make(age: 8)
        harness.events.continuation.yield(shared)
        harness.events.continuation.yield(liveOnly)
        harness.drained.continuation.yield(shared)
        harness.drained.continuation.yield(drainedOnly)
        await harness.settle(store)
        XCTAssertEqual(store.events.map(\.id), [liveOnly.id, shared.id, drainedOnly.id])
    }

    func testLateOlderEventIsOrderedByTimestamp() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        let newer = EventFixture.make(age: 1)
        let middle = EventFixture.make(age: 50)
        let older = EventFixture.make(age: 100)
        harness.events.continuation.yield(older)
        harness.events.continuation.yield(newer)
        harness.events.continuation.yield(middle)
        await harness.settle(store)
        XCTAssertEqual(store.events.map(\.id), [newer.id, middle.id, older.id])
    }

    func testEvictsOldestByTimestampAndNeverReadmitsIt() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        let oldest = EventFixture.make(age: 10000)
        harness.events.continuation.yield(oldest)
        let rest = (0 ..< AppStateStore.maxEvents - 1).map { EventFixture.make(age: Double(1000 - $0)) }
        for event in rest {
            harness.events.continuation.yield(event)
        }
        let newest = EventFixture.make(age: 0)
        let tooOld = EventFixture.make(age: 20000)
        harness.events.continuation.yield(newest)
        harness.events.continuation.yield(oldest)
        harness.events.continuation.yield(tooOld)
        await harness.settle(store)
        XCTAssertEqual(store.events.count, AppStateStore.maxEvents)
        XCTAssertEqual(store.events.first?.id, newest.id)
        XCTAssertFalse(store.events.contains { $0.id == oldest.id })
        XCTAssertFalse(store.events.contains { $0.id == tooOld.id })
        XCTAssertEqual(store.events.last?.id, rest.first?.id)
    }
}
