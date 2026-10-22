import Foundation
import Synchronization
import XCTest

private final class NoCache: CacheClearing {
    func clearCache() {}
}

/// Records pushed events and lets a test await the next one without sleeping.
private final class FakeClient: NSObject, WardenClientXPC, Sendable {
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    override init() {
        (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        super.init()
    }

    func eventRecorded(_ eventData: Data) async {
        continuation.yield(eventData)
    }

    /// Next pushed event, or nil after 10 s so a broken forwarder fails the test instead of hanging it.
    func next() async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { [stream] in
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// A peer that never answers: `eventRecorded` suspends until `release()`.
private final class HangingClient: NSObject, WardenClientXPC, Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    override init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        super.init()
    }

    func eventRecorded(_: Data) async {
        for await _ in stream {}
    }

    func release() {
        continuation.finish()
    }
}

final class ExtensionServiceTests: XCTestCase {
    private struct Rig {
        let service: ExtensionService
        let events: EventQueue
        let holder: PolicyHolder
    }

    private func make() throws -> (Rig, URL) {
        let dir = try PolicyFixtures.makeTempDir()
        let holder = PolicyHolder()
        let controller = PolicyController(
            holder: holder, store: PolicyStore(fileURL: dir.appendingPathComponent("policy.json")),
            cache: NoCache(), log: { _ in }
        )
        let events = EventQueue()
        return (Rig(service: ExtensionService(policy: controller, events: events), events: events, holder: holder), dir)
    }

    private func event(_ number: Int) -> AccessEvent {
        AccessEvent(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID(),
            timestamp: Date(timeIntervalSince1970: Double(number)),
            process: ProcessIdentity(path: "/bin/cat", signingId: "", teamId: ""),
            responsible: nil, file: "/secret/\(number)", decision: .deny, ruleId: "r1"
        )
    }

    func testApplyReturnsVersion() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let version = try await rig.service.apply(policyData: PolicyFixtures.policy(version: 7))
        XCTAssertEqual(version, 7)
        let current = await rig.service.currentPolicyVersion()
        XCTAssertEqual(current, 7)
    }

    func testApplyInvalidThrowsWithValidationLines() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await rig.service.apply(policyData: PolicyFixtures.policy(version: 3))
        do {
            _ = try await rig.service.apply(policyData: Data("{}".utf8))
            XCTFail("expected an error")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "io.github.eugenehil.warden")
            let lines = nsError.userInfo[WardenXPCError.validationErrorsKey] as? [String]
            XCTAssertFalse(lines?.isEmpty ?? true)
            XCTAssertEqual(nsError.code, WardenXPCError.invalidPolicyCode)
        }
        let current = await rig.service.currentPolicyVersion()
        XCTAssertEqual(current, 3)
    }

    func testCurrentPolicyVersionIsZeroBeforeApply() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = await rig.service.currentPolicyVersion()
        XCTAssertEqual(current, 0)
    }

    func testDrainReturnsEncodedEventsAndEmpties() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorded = [event(1), event(2)]
        for item in recorded {
            await rig.events.record(item)
        }
        let data = await rig.service.drainEvents(max: 10)
        XCTAssertEqual(try XPCCoding.decodeList(data), recorded)
        let again = await rig.service.drainEvents(max: 10)
        XCTAssertEqual(try XPCCoding.decodeList(again), [])
    }

    func testEventsRecordedBeforeSubscribeStayDrainable() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        await rig.events.record(event(1))
        await rig.service.subscribe(client: FakeClient())
        let data = await rig.service.drainEvents(max: 10)
        XCTAssertEqual(try XPCCoding.decodeList(data), [event(1)])
    }

    func testSubscribedClientReceivesRecordedEvent() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = FakeClient()
        await rig.service.subscribe(client: client)
        await rig.events.record(event(5))
        let data = await client.next()
        let received = try XPCCoding.decode(XCTUnwrap(data))
        XCTAssertEqual(received, event(5))
    }

    func testEveryClientReceivesEvent() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FakeClient()
        let second = FakeClient()
        await rig.service.subscribe(client: first)
        await rig.service.subscribe(client: second)
        await rig.events.record(event(9))
        let firstData = await first.next()
        let secondData = await second.next()
        XCTAssertEqual(try XPCCoding.decode(XCTUnwrap(firstData)), event(9))
        XCTAssertEqual(try XPCCoding.decode(XCTUnwrap(secondData)), event(9))
    }

    func testInvalidatedConnectionClientIsRemoved() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connectionA = NSObject()
        let connectionB = NSObject()
        let gone = FakeClient()
        let kept = FakeClient()
        await rig.service.subscribe(client: gone, connectionKey: ObjectIdentifier(connectionA))
        await rig.service.subscribe(client: kept, connectionKey: ObjectIdentifier(connectionB))
        var count = await rig.service.subscriberCount()
        XCTAssertEqual(count, 2)
        await rig.service.removeClients(connectionKey: ObjectIdentifier(connectionA))
        count = await rig.service.subscriberCount()
        XCTAssertEqual(count, 1)
        await rig.events.record(event(1))
        let data = await kept.next()
        XCTAssertEqual(try XPCCoding.decode(XCTUnwrap(data)), event(1))
    }

    func testResubscribeOnSameConnectionDoesNotDuplicate() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connection = NSObject()
        let key = ObjectIdentifier(connection)
        let old = FakeClient()
        let fresh = FakeClient()
        await rig.service.subscribe(client: old, connectionKey: key)
        await rig.service.subscribe(client: fresh, connectionKey: key)
        let count = await rig.service.subscriberCount()
        XCTAssertEqual(count, 1)
        await rig.events.record(event(1))
        let data = await fresh.next()
        XCTAssertEqual(try XPCCoding.decode(XCTUnwrap(data)), event(1))
    }

    func testStuckClientDoesNotBlockOthers() async throws {
        let (rig, dir) = try make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stuck = HangingClient()
        defer { stuck.release() }
        let healthy = FakeClient()
        await rig.service.subscribe(client: stuck, connectionKey: ObjectIdentifier(stuck))
        await rig.service.subscribe(client: healthy, connectionKey: ObjectIdentifier(healthy))
        for number in 1 ... 3 {
            await rig.events.record(event(number))
        }
        for number in 1 ... 3 {
            let data = await healthy.next()
            XCTAssertEqual(try XPCCoding.decode(XCTUnwrap(data)), event(number))
        }
    }

    func testPeerRequirementPinsBundleIdentifier() {
        XCTAssertEqual(ExtensionService.peerRequirement(), #"identifier "io.github.eugenehil.warden""#)
    }
}
