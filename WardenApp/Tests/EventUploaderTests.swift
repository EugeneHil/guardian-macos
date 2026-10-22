import Foundation
import XCTest

final class EventUploaderTests: XCTestCase {
    private struct Rig {
        let api = FakeAgentAPI()
        let link = FakeExtensionLink()
        let clock = ManualClock()
        let uploader: EventUploader

        init(maxPending: Int = 5000) {
            uploader = EventUploader(api: api, link: link, clock: clock, maxPending: maxPending)
        }
    }

    private static func events(_ count: Int, from start: Int = 0, file: String = "/data/file") -> [AccessEvent] {
        (start ..< start + count).map { index in
            AccessEvent(
                id: UUID(), timestamp: Date(timeIntervalSince1970: Double(index)),
                process: ProcessIdentity(path: "/bin/tool", signingId: "id", teamId: "T"),
                responsible: nil, file: "\(file)\(index)", decision: .deny, ruleId: nil
            )
        }
    }

    func testUploadsDrainedEventsInOrder() async {
        let rig = Rig()
        let sent = Self.events(3)
        rig.link.enqueue(sent)
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postedBatches, [sent])
        let pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testBatchesAreAtMost500() async {
        let rig = Rig()
        rig.link.enqueue(Self.events(1200))
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postedBatches.map(\.count), [500, 500, 200])
        XCTAssertEqual(Set(rig.link.drainMaxes), [500])
    }

    func testKeepsBatchOnServerError() async {
        let rig = Rig()
        let sent = Self.events(3)
        rig.link.enqueue(sent)
        rig.api.setPostHandler { _ in throw AgentAPIError.server(503) }
        await rig.uploader.flushNow()
        var pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 3)
        rig.api.setPostHandler { _ in }
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postedBatches, [sent, sent])
        pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testDropsBatchOnInvalidEvents() async {
        let rig = Rig()
        rig.link.enqueue(Self.events(3))
        rig.api.setPostHandler { _ in throw AgentAPIError.invalidBatch }
        await rig.uploader.flushNow()
        let pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(rig.api.postCalls.count, 1)
    }

    func testUnauthorizedStopsUploading() async {
        let rig = Rig()
        rig.link.enqueue(Self.events(2))
        rig.api.setPostHandler { _ in throw AgentAPIError.unauthorized }
        await rig.uploader.flushNow()
        rig.link.enqueue(Self.events(2, from: 2))
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postCalls.count, 1)
        XCTAssertEqual(rig.link.drainCalls.count, 1, "a paused uploader leaves events in the extension")
        rig.api.setPostHandler { _ in }
        await rig.uploader.resume()
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postedBatches.last?.count, 4)
        let pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testPendingIsBoundedAndDropsOldest() async {
        let rig = Rig(maxPending: 5000)
        let all = Self.events(10000)
        rig.link.enqueue(all)
        rig.api.setPostHandler { _ in throw AgentAPIError.transport }
        await rig.uploader.flushNow()
        let pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 5000)
        XCTAssertEqual(rig.api.postedBatches.first?.first, all[5000])
    }

    func testThrottledWaitsRetryAfter() async {
        let rig = Rig()
        rig.link.enqueue(Self.events(2))
        let attempts = CallLatch()
        rig.api.setPostHandler { _ in
            attempts.increment()
            if attempts.count == 1 {
                throw AgentAPIError.throttled(retryAfter: .seconds(30))
            }
        }
        let task = Task { await rig.uploader.run() }
        await rig.api.postCalls.wait(for: 1)
        await rig.clock.waitForSleepers(1)
        rig.clock.advance(by: .seconds(29))
        XCTAssertEqual(rig.clock.sleeperCount, 1)
        XCTAssertEqual(rig.api.postCalls.count, 1)
        rig.clock.advance(by: .seconds(1))
        await rig.api.postCalls.wait(for: 2)
        task.cancel()
        await task.value
    }

    func testRunLoopTicksEveryInterval() async {
        let rig = Rig()
        let task = Task { await rig.uploader.run() }
        await rig.link.drainCalls.wait(for: 1)
        await rig.clock.waitForSleepers(1)
        rig.link.enqueue(Self.events(1))
        rig.clock.advance(by: .seconds(5))
        await rig.api.postCalls.wait(for: 1)
        task.cancel()
        await task.value
    }

    func testEmptyDrainSendsNothing() async {
        let rig = Rig()
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postCalls.count, 0)
        XCTAssertEqual(rig.link.drainCalls.count, 1)
    }

    func testPayloadTooLargeSplitsBatchInHalf() async {
        let rig = Rig()
        rig.link.enqueue(Self.events(4))
        rig.api.setPostHandler { events in
            if events.count > 2 {
                throw AgentAPIError.payloadTooLarge
            }
        }
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postedBatches.map(\.count), [4, 2, 2])
        let pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testPayloadTooLargeDropsSingleEvent() async {
        let rig = Rig()
        let sent = Self.events(3)
        let oversized = sent[1].id
        rig.link.enqueue(sent)
        rig.api.setPostHandler { events in
            if events.contains(where: { $0.id == oversized }) {
                throw AgentAPIError.payloadTooLarge
            }
        }
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postedBatches.map(\.count), [3, 1, 1, 1])
        XCTAssertEqual(rig.api.postedBatches.last, [sent[2]])
        let pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testBatchesAreBoundedByEncodedBytes() async throws {
        let rig = Rig()
        rig.link.enqueue(Self.events(300, file: String(repeating: "x", count: 4000)))
        await rig.uploader.flushNow()
        let batches = rig.api.postedBatches
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.map(\.count).reduce(0, +), 300)
        for batch in batches {
            let size = try AccessEvent.uploadPayload(batch).count
            XCTAssertLessThanOrEqual(size, 900 * 1024)
        }
    }

    func testUnavailableDrainKeepsPendingAndContinues() async {
        let rig = Rig()
        let sent = Self.events(3)
        rig.link.enqueue(sent)
        rig.api.setPostHandler { _ in throw AgentAPIError.server(500) }
        await rig.uploader.flushNow()
        rig.link.setDrainError(.unavailable)
        rig.api.setPostHandler { _ in }
        await rig.uploader.flushNow()
        XCTAssertEqual(rig.api.postedBatches, [sent, sent])
        let pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 0)
    }

    private static func firstDrained(_ uploader: EventUploader, count: Int) async -> [AccessEvent] {
        var result: [AccessEvent] = []
        for await event in uploader.drained {
            result.append(event)
            if result.count == count {
                break
            }
        }
        return result
    }

    func testPublishesDrainedEvents() async {
        let rig = Rig()
        let sent = Self.events(3)
        rig.link.enqueue(sent)
        await rig.uploader.flushNow()
        let drained = await Self.firstDrained(rig.uploader, count: 3)
        XCTAssertEqual(drained, sent)
    }

    func testPublishesDrainedEventsEvenWhenUploadFails() async {
        let rig = Rig()
        let sent = Self.events(2)
        rig.link.enqueue(sent)
        rig.api.setPostHandler { _ in throw AgentAPIError.transport }
        await rig.uploader.flushNow()
        let drained = await Self.firstDrained(rig.uploader, count: 2)
        XCTAssertEqual(drained, sent)
        let pending = await rig.uploader.pendingCount
        XCTAssertEqual(pending, 2)
    }

    func testDrainedBufferMatchesTheStoreCap() {
        XCTAssertEqual(EventUploader.drainedBufferSize, AppStateStore.maxEvents)
    }
}
