import Foundation
import XCTest

final class ExtensionLinkTests: XCTestCase {
    private struct Rig {
        let first = FakeExtensionService()
        let second = FakeExtensionService()
        let provider: FakeXPCConnectionProvider
        let clock = ManualClock()
        let link: ExtensionLink

        init() {
            provider = FakeXPCConnectionProvider(services: [first, second])
            link = ExtensionLink(provider: provider, clock: clock)
        }
    }

    private static func event(_ decision: AccessDecision = .deny, file: String = "/Users/a/proj/.env") -> AccessEvent {
        AccessEvent(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            process: ProcessIdentity(path: "/bin/cat", signingId: "com.apple.cat", teamId: ""),
            responsible: nil, file: file, decision: decision, ruleId: "r1"
        )
    }

    private static func interrupted() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
    }

    func testForwardsApplyAndReturnsVersion() async throws {
        let rig = Rig()
        rig.first.setApplyResult(.success(7))
        let policy = Data(#"{"version":7}"#.utf8)
        let version = try await rig.link.apply(policy: policy)
        XCTAssertEqual(version, 7)
        XCTAssertEqual(rig.first.applied, [policy])
        let current = try await rig.link.currentPolicyVersion()
        XCTAssertEqual(current, 0, "0 means no policy yet and is returned as is")
        XCTAssertEqual(rig.provider.sessions.count, 1, "the connection is reused")
        XCTAssertEqual(rig.first.subscribeCalls.count, 1, "subscribe is sent once per connection")
    }

    func testTimeoutThrowsUnavailable() async throws {
        let rig = Rig()
        rig.first.setHangs(true)
        let call = Task { try await rig.link.apply(policy: Data("{}".utf8)) }
        await rig.first.hungCalls.wait(for: 1)
        await rig.clock.waitForSleepers(1)
        rig.clock.advance(by: .seconds(5))
        do {
            _ = try await call.value
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? ExtensionLinkError, .unavailable)
        }
        let session = try XCTUnwrap(rig.provider.sessions.first)
        XCTAssertEqual(session.invalidations.count, 1, "a timed-out connection is dropped")

        rig.first.releaseHung() // the late reply must be ignored safely
        rig.second.setVersion(3)
        let version = try await rig.link.currentPolicyVersion()
        XCTAssertEqual(version, 3)
        XCTAssertEqual(rig.provider.sessions.count, 2)
        XCTAssertEqual(rig.second.subscribeCalls.count, 1)
    }

    func testConnectionErrorFailsFastWithoutTimeout() async throws {
        let rig = Rig()
        rig.first.setFailsViaErrorHandler(true) // e.g. the Mach lookup fails: the extension is not installed
        do {
            _ = try await rig.link.currentPolicyVersion()
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? ExtensionLinkError, .unavailable)
        }
        let first = try XCTUnwrap(rig.provider.sessions.first)
        XCTAssertEqual(first.invalidations.count, 1, "a failed connection is dropped")
        XCTAssertEqual(rig.clock.now.offset, .zero, "no timeout was needed")

        _ = try await rig.link.currentPolicyVersion()
        rig.second.setFailsViaErrorHandler(true) // the connection fails after subscribing
        do {
            _ = try await rig.link.apply(policy: Data("{}".utf8))
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? ExtensionLinkError, .unavailable)
        }
        XCTAssertEqual(rig.provider.sessions.count, 2)
        XCTAssertEqual(rig.provider.sessions.last?.invalidations.count, 1)
    }

    func testCancelledCallerThrowsCancellationAndKeepsConnection() async throws {
        let rig = Rig()
        _ = try await rig.link.currentPolicyVersion()
        rig.first.setHangs(true)
        let call = Task { try await rig.link.apply(policy: Data("{}".utf8)) }
        await rig.first.hungCalls.wait(for: 1)
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        let session = try XCTUnwrap(rig.provider.sessions.first)
        XCTAssertEqual(session.invalidations.count, 0, "cancellation does not drop the connection")
        rig.first.setHangs(false)
        rig.first.releaseHung()
        rig.first.setVersion(4)
        let version = try await rig.link.currentPolicyVersion()
        XCTAssertEqual(version, 4)
        XCTAssertEqual(rig.provider.sessions.count, 1)
    }

    func testInterruptionThrowsThenReconnectsAndResubscribes() async throws {
        let rig = Rig()
        rig.first.setApplyResult(.failure(Self.interrupted()))
        do {
            _ = try await rig.link.apply(policy: Data("{}".utf8))
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? ExtensionLinkError, .unavailable)
        }
        rig.second.setApplyResult(.success(2))
        let version = try await rig.link.apply(policy: Data("{}".utf8))
        XCTAssertEqual(version, 2)
        XCTAssertEqual(rig.provider.sessions.count, 2)
        XCTAssertEqual(rig.first.subscribeCalls.count, 1)
        XCTAssertEqual(rig.second.subscribeCalls.count, 1, "subscribe is re-sent on the new connection")
    }

    func testInterruptionBetweenCallsReconnectsOnNextCall() async throws {
        let rig = Rig()
        _ = try await rig.link.currentPolicyVersion()
        let session = try XCTUnwrap(rig.provider.sessions.first)
        session.interrupt()
        await session.invalidations.wait(for: 1)
        rig.second.setVersion(5)
        let version = try await rig.link.currentPolicyVersion()
        XCTAssertEqual(version, 5)
        XCTAssertEqual(rig.provider.sessions.count, 2)
        XCTAssertEqual(rig.second.subscribeCalls.count, 1)
    }

    func testRejectedPolicyMapsToInvalidPolicy() async throws {
        let rig = Rig()
        let rejection = NSError(
            domain: GuardianXPCError.domain, code: GuardianXPCError.invalidPolicyCode,
            userInfo: [GuardianXPCError.validationErrorsKey: ["rules[0].target: empty"]]
        )
        rig.first.setApplyResult(.failure(rejection))
        do {
            _ = try await rig.link.apply(policy: Data("{}".utf8))
            XCTFail("expected invalidPolicy")
        } catch {
            XCTAssertEqual(error as? ExtensionLinkError, .invalidPolicy(["rules[0].target: empty"]))
        }
        _ = try await rig.link.currentPolicyVersion()
        XCTAssertEqual(rig.provider.sessions.count, 1, "a rejected policy keeps the connection")
    }

    func testOtherErrorsMapToUnavailable() {
        let otherDomain = NSError(domain: "other", code: GuardianXPCError.invalidPolicyCode)
        let otherCode = NSError(domain: GuardianXPCError.domain, code: 99)
        XCTAssertEqual(ExtensionLink.map(otherDomain), .unavailable)
        XCTAssertEqual(ExtensionLink.map(otherCode), .unavailable)
        XCTAssertEqual(ExtensionLink.map(Self.interrupted()), .unavailable)
        let invalidated = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)
        XCTAssertEqual(ExtensionLink.map(invalidated), .unavailable)
    }

    func testConnectFailureThrowsUnavailable() async {
        let rig = Rig()
        rig.provider.setFailsToConnect(true)
        do {
            _ = try await rig.link.currentPolicyVersion()
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? ExtensionLinkError, .unavailable)
        }
    }

    func testLiveEventsAreDecodedFromClientCallback() async throws {
        let rig = Rig()
        let events = rig.link.liveEvents()
        _ = try await rig.link.currentPolicyVersion()
        let client = try XCTUnwrap(rig.first.clients.first)
        XCTAssertTrue(client === rig.provider.exported.first, "the subscribed client is the exported object")
        let sent = Self.event()
        client.eventRecorded(Data("not json".utf8)) // undecodable payloads are dropped
        try client.eventRecorded(XPCCoding.encode(sent))
        var iterator = events.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, sent)
    }

    func testDrainDecodesEvents() async throws {
        let rig = Rig()
        let sent = [Self.event(), Self.event(.allow, file: "/tmp/other")]
        try rig.first.setDrainData(JSONEncoder.xpc.encode(sent))
        let drained = try await rig.link.drainEvents(max: 10)
        XCTAssertEqual(drained, sent)
        XCTAssertEqual(rig.first.drainMaxes, [10])

        rig.first.setDrainData(Data("garbage".utf8))
        do {
            _ = try await rig.link.drainEvents(max: 10)
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? ExtensionLinkError, .unavailable)
        }
    }

    func testPeerRequirementPinsExtensionIdentifier() {
        XCTAssertEqual(MachServiceConnector.peerRequirement(), #"identifier "io.github.eugenehil.guardian.ext""#)
    }
}
