import Foundation
import XCTest

final class PolicySyncServiceTests: XCTestCase {
    private static let fixedNow = Date(timeIntervalSince1970: 1000)

    private struct Rig {
        let api = FakeAgentAPI()
        let link = FakeExtensionLink()
        let clock = ManualClock()
        let service: PolicySyncService

        init() {
            service = PolicySyncService(
                api: api, link: link, clock: clock, now: { PolicySyncServiceTests.fixedNow }
            )
        }
    }

    private static func policy(_ version: Int64) -> Result<PolicyFetchResult, AgentAPIError> {
        let body = Data(#"{"rules":[],"schemaVersion":1,"version":\#(version)}"#.utf8)
        return .success(.modified(body: body, etag: "\"v\(version)\"", version: version))
    }

    private static func body(_ version: Int64) -> Data {
        Data(#"{"rules":[],"schemaVersion":1,"version":\#(version)}"#.utf8)
    }

    // MARK: - Single ticks

    func testFirstFetchPushesToExtension() async {
        let rig = Rig()
        rig.api.script(Self.policy(1))
        await rig.service.syncNow()
        XCTAssertEqual(rig.api.fetchEtags, [nil])
        XCTAssertEqual(rig.link.applied, [Self.body(1)])
        let state = await rig.service.state
        XCTAssertEqual(state, .synced(version: 1, at: Self.fixedNow))
    }

    func testSecondTickSendsIfNoneMatch() async {
        let rig = Rig()
        rig.link.setCurrentVersion(.success(1))
        rig.api.script(Self.policy(1), .success(.notModified))
        await rig.service.syncNow()
        await rig.service.syncNow()
        XCTAssertEqual(rig.api.fetchEtags, [nil, "\"v1\""])
    }

    func testNotModifiedKeepsState() async {
        let rig = Rig()
        rig.link.setCurrentVersion(.success(1))
        rig.api.script(Self.policy(1), .success(.notModified))
        await rig.service.syncNow()
        await rig.service.syncNow()
        XCTAssertEqual(rig.link.applied.count, 1)
        let state = await rig.service.state
        XCTAssertEqual(state, .synced(version: 1, at: Self.fixedNow))
    }

    func testExtensionRestartRepushesWhenVersionsDiffer() async {
        let rig = Rig()
        rig.api.script(Self.policy(1), .success(.notModified))
        await rig.service.syncNow()
        rig.link.setCurrentVersion(.success(0))
        await rig.service.syncNow()
        XCTAssertEqual(rig.link.applied, [Self.body(1), Self.body(1)])
        let state = await rig.service.state
        XCTAssertEqual(state, .synced(version: 1, at: Self.fixedNow))
    }

    func testApplyFailureShowsExtensionUnavailableAndRetries() async {
        let rig = Rig()
        rig.api.script(Self.policy(1))
        rig.link.scriptApply(.failure(.unavailable), .success(nil))
        await rig.service.syncNow()
        var state = await rig.service.state
        XCTAssertEqual(state, .extensionUnavailable(version: 1))
        await rig.service.syncNow()
        XCTAssertEqual(rig.api.fetchEtags, [nil, nil])
        XCTAssertEqual(rig.link.applied.count, 2)
        state = await rig.service.state
        XCTAssertEqual(state, .synced(version: 1, at: Self.fixedNow))
    }

    func testUnavailableWhileComparingVersionsClearsEtag() async {
        let rig = Rig()
        rig.api.script(Self.policy(1), .success(.notModified))
        await rig.service.syncNow()
        rig.link.setCurrentVersion(.failure(.unavailable))
        await rig.service.syncNow()
        var state = await rig.service.state
        XCTAssertEqual(state, .extensionUnavailable(version: 1))
        await rig.service.syncNow()
        XCTAssertEqual(rig.api.fetchEtags, [nil, "\"v1\"", nil])
        state = await rig.service.state
        XCTAssertEqual(state, .extensionUnavailable(version: 1))
    }

    func testRejectedPolicyIsNotRepushedUntilEtagChanges() async {
        let rig = Rig()
        rig.api.script(Self.policy(1), Self.policy(2), Self.policy(2), Self.policy(3))
        rig.link.scriptApply(.success(nil), .failure(.invalidPolicy(["bad"])), .success(nil))
        await rig.service.syncNow()
        await rig.service.syncNow()
        var state = await rig.service.state
        XCTAssertEqual(state, .extensionUnavailable(version: 1))
        await rig.service.syncNow()
        XCTAssertEqual(rig.link.applied, [Self.body(1), Self.body(2)], "the rejected policy must not be re-pushed")
        XCTAssertEqual(rig.api.fetchEtags, [nil, "\"v1\"", "\"v1\""], "the last good ETag stays")
        state = await rig.service.state
        XCTAssertEqual(state, .extensionUnavailable(version: 1))
        await rig.service.syncNow()
        XCTAssertEqual(rig.link.applied, [Self.body(1), Self.body(2), Self.body(3)])
        state = await rig.service.state
        XCTAssertEqual(state, .synced(version: 3, at: Self.fixedNow))
    }

    func testServerDownKeepsLastGoodPolicy() async {
        let rig = Rig()
        rig.api.script(Self.policy(2), .failure(.server(503)))
        await rig.service.syncNow()
        await rig.service.syncNow()
        let state = await rig.service.state
        XCTAssertEqual(state, .unreachable(lastVersion: 2))
        XCTAssertEqual(rig.link.applyCalls.count, 1)
    }

    func testMalformedResponseDoesNotReplacePolicy() async {
        let rig = Rig()
        rig.api.script(Self.policy(2), .failure(.malformedResponse))
        await rig.service.syncNow()
        await rig.service.syncNow()
        let state = await rig.service.state
        XCTAssertEqual(state, .unreachable(lastVersion: 2))
        XCTAssertEqual(rig.link.applied, [Self.body(2)])
    }

    func testUnreachableBeforeAnyPolicyHasNoVersion() async {
        let rig = Rig()
        rig.api.script(.failure(.transport))
        await rig.service.syncNow()
        let state = await rig.service.state
        XCTAssertEqual(state, .unreachable(lastVersion: nil))
    }

    func testNotConfiguredState() async {
        let rig = Rig()
        rig.api.script(.failure(.notConfigured))
        await rig.service.syncNow()
        let state = await rig.service.state
        XCTAssertEqual(state, .notConfigured)
    }

    // MARK: - Run loop

    func testRunLoopFetchesEveryInterval() async {
        let rig = Rig()
        rig.api.script(Self.policy(1))
        let task = Task { await rig.service.run() }
        await rig.api.fetchCalls.wait(for: 1)
        await rig.clock.waitForSleepers(1)
        rig.clock.advance(by: .seconds(10))
        await rig.api.fetchCalls.wait(for: 2)
        task.cancel()
        await task.value
    }

    func testUnauthorizedStopsPollingUntilResume() async {
        let rig = Rig()
        rig.api.script(.failure(.unauthorized))
        let task = Task { await rig.service.run() }
        await rig.api.fetchCalls.wait(for: 1)
        for _ in 0 ..< 3 {
            await rig.clock.waitForSleepers(1)
            rig.clock.advance(by: .seconds(10))
        }
        await rig.clock.waitForSleepers(1)
        XCTAssertEqual(rig.api.fetchCalls.count, 1)
        var state = await rig.service.state
        XCTAssertEqual(state, .unauthorized)

        rig.api.script(Self.policy(1))
        await rig.service.resume()
        rig.clock.advance(by: .seconds(10))
        await rig.api.fetchCalls.wait(for: 2)
        await rig.clock.waitForSleepers(1)
        state = await rig.service.state
        XCTAssertEqual(state, .synced(version: 1, at: Self.fixedNow))
        task.cancel()
        await task.value
    }

    func testThrottleWaitsRetryAfter() async {
        let rig = Rig()
        rig.api.script(.failure(.throttled(retryAfter: .seconds(120))), Self.policy(1))
        let task = Task { await rig.service.run() }
        await rig.api.fetchCalls.wait(for: 1)
        await rig.clock.waitForSleepers(1)
        let state = await rig.service.state
        XCTAssertEqual(state, .throttled(until: Self.fixedNow.addingTimeInterval(120)))
        rig.clock.advance(by: .seconds(119))
        XCTAssertEqual(rig.clock.sleeperCount, 1)
        XCTAssertEqual(rig.api.fetchCalls.count, 1)
        rig.clock.advance(by: .seconds(1))
        await rig.api.fetchCalls.wait(for: 2)
        task.cancel()
        await task.value
    }

    func testSyncNowTriggersImmediateFetch() async {
        let rig = Rig()
        rig.api.script(Self.policy(1))
        let task = Task { await rig.service.run() }
        await rig.api.fetchCalls.wait(for: 1)
        await rig.clock.waitForSleepers(1)
        await rig.service.syncNow()
        XCTAssertEqual(rig.api.fetchCalls.count, 2)
        task.cancel()
        await task.value
    }

    func testStatesStreamPublishesChanges() async {
        let rig = Rig()
        rig.api.script(Self.policy(1))
        var iterator = rig.service.states.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, .idle)
        await rig.service.syncNow()
        let next = await iterator.next()
        XCTAssertEqual(next, .synced(version: 1, at: Self.fixedNow))
    }
}
