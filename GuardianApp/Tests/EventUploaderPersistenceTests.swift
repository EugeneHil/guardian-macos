import XCTest

final class EventUploaderPersistenceTests: XCTestCase {
    func testRestoredEventsAreUploadedFirstAndNotYielded() async {
        let restored = EventUploaderTests.events(2)
        let fresh = EventUploaderTests.events(2, from: 10)
        let store = InMemoryPendingEventStore(events: restored)
        let rig = EventUploaderTests.Rig(store: store)
        rig.link.enqueue(fresh)
        let task = Task { await rig.uploader.run() }
        await rig.api.postCalls.wait(for: 1)
        task.cancel()
        await task.value
        XCTAssertEqual(rig.api.postedBatches, [restored + fresh])
        let drained = await EventUploaderTests.firstDrained(rig.uploader, count: 2)
        XCTAssertEqual(drained, fresh)
        XCTAssertEqual(store.events, [])
    }

    func testSavesAfterDrainBeforeUploadAndEmptiesAfterUpload() async {
        let store = InMemoryPendingEventStore()
        let rig = EventUploaderTests.Rig(store: store)
        let sent = EventUploaderTests.events(3)
        rig.link.enqueue(sent)
        let storedDuringUpload = CallLatch()
        rig.api.setPostHandler { _ in
            if store.events.count == 3 {
                storedDuringUpload.increment()
            }
        }
        await rig.uploader.flushNow()
        XCTAssertEqual(storedDuringUpload.count, 1, "events are durable before the upload starts")
        XCTAssertEqual(store.events, [])
        XCTAssertEqual(store.saves.last, [])
    }

    func testFailedUploadLeavesEventsInTheStore() async {
        let store = InMemoryPendingEventStore()
        let rig = EventUploaderTests.Rig(store: store)
        let sent = EventUploaderTests.events(3)
        rig.link.enqueue(sent)
        rig.api.setPostHandler { _ in throw AgentAPIError.server(503) }
        await rig.uploader.flushNow()
        XCTAssertEqual(store.events, sent)
    }

    func testDroppedBatchIsRemovedFromTheStore() async {
        let store = InMemoryPendingEventStore()
        let rig = EventUploaderTests.Rig(store: store)
        rig.link.enqueue(EventUploaderTests.events(3))
        rig.api.setPostHandler { _ in throw AgentAPIError.invalidBatch }
        await rig.uploader.flushNow()
        XCTAssertEqual(store.events, [])
    }

    func testRestoredEventsAreTrimmedToMaxPendingKeepingNewest() async {
        let restored = EventUploaderTests.events(10)
        let store = InMemoryPendingEventStore(events: restored)
        let rig = EventUploaderTests.Rig(maxPending: 4, store: store)
        rig.api.setPostHandler { _ in throw AgentAPIError.transport }
        let task = Task { await rig.uploader.run() }
        await rig.api.postCalls.wait(for: 1)
        task.cancel()
        await task.value
        XCTAssertEqual(rig.api.postedBatches.first, Array(restored.suffix(4)))
        XCTAssertEqual(store.events, Array(restored.suffix(4)))
    }

    func testStoreFailureDoesNotStopTheUploader() async {
        let store = InMemoryPendingEventStore()
        store.failSaves(true)
        let rig = EventUploaderTests.Rig(store: store)
        let sent = EventUploaderTests.events(2)
        rig.link.enqueue(sent)
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postedBatches, [sent])
        let pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testReportsPausedAfterUnauthorized() async {
        let rig = EventUploaderTests.Rig()
        rig.link.enqueue(EventUploaderTests.events(1))
        rig.api.setPostHandler { _ in throw AgentAPIError.unauthorized }
        await rig.uploader.flushNow()
        let paused = await rig.uploader.isPaused
        XCTAssertTrue(paused)
    }
}
