import XCTest

@MainActor
final class EventsViewModelTests: XCTestCase {
    private func makeModel(_ events: [AccessEvent]) async -> EventsViewModel {
        let harness = StoreHarness()
        let store = harness.makeStore()
        for event in events {
            harness.events.continuation.yield(event)
        }
        await harness.settle(store)
        return EventsViewModel(store: store, now: { EventFixture.now }, home: "/Users/eugene")
    }

    func testBlockedOnlyFiltersAllowEvents() async {
        let denied = EventFixture.make(decision: .deny, ruleId: "r1")
        let allowedWithRule = EventFixture.make(decision: .allow, ruleId: "r1")
        let allowed = EventFixture.make(decision: .allow, ruleId: nil)
        let model = await makeModel([denied, allowedWithRule, allowed])
        XCTAssertEqual(model.rows.count, 3)
        model.blockedOnly = true
        XCTAssertEqual(model.rows.map(\.id), [denied.id])
        model.blockedOnly = false
        XCTAssertEqual(model.rows.count, 3)
    }
}
