import Foundation
import Synchronization
import XCTest

/// The real NSXPC proxy cannot run in unit tests, so wire compatibility of the reply-block mirror is checked through
/// the Objective-C runtime and the bridging is checked against a scripted raw proxy.
final class ReplyBridgeTests: XCTestCase {
    // MARK: Wire parity

    private struct MethodSignature: Hashable {
        let selector: String
        let types: String
        let extendedTypes: String
    }

    private typealias ExtendedEncoding = @convention(c) (Protocol, Selector, Bool, Bool) -> UnsafePointer<CChar>?

    /// `_protocol_getMethodTypeEncoding` is the libobjc function NSXPCInterface itself uses to read the full
    /// signatures (block arguments included); it is not in the public headers, so it is looked up at run time.
    private static func extendedEncoding() throws -> ExtendedEncoding {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        let symbol = try XCTUnwrap(dlsym(defaultHandle, "_protocol_getMethodTypeEncoding"))
        return unsafeBitCast(symbol, to: ExtendedEncoding.self)
    }

    private static func signatures(of proto: Protocol, required: Bool, instance: Bool) throws -> Set<MethodSignature> {
        let encoding = try extendedEncoding()
        var count: UInt32 = 0
        guard let list = protocol_copyMethodDescriptionList(proto, required, instance, &count) else {
            return []
        }
        defer { free(list) }
        var result = Set<MethodSignature>()
        for index in 0 ..< Int(count) {
            let method = list[index]
            let selector = try XCTUnwrap(method.name)
            let types = try XCTUnwrap(method.types)
            let extended = try XCTUnwrap(encoding(proto, selector, required, instance))
            result.insert(MethodSignature(
                selector: NSStringFromSelector(selector), types: String(cString: types),
                extendedTypes: String(cString: extended)
            ))
        }
        return result
    }

    func testMirrorIsWireCompatibleWithExtensionProtocol() throws {
        for (required, instance) in [(true, true), (false, true), (true, false), (false, false)] {
            let mirror = try Self.signatures(of: WardenExtensionReplyXPC.self, required: required, instance: instance)
            let shared = try Self.signatures(of: WardenExtensionXPC.self, required: required, instance: instance)
            XCTAssertEqual(mirror, shared, "required: \(required), instance: \(instance)")
        }
        let methods = try Self.signatures(of: WardenExtensionXPC.self, required: true, instance: true)
        XCTAssertEqual(Set(methods.map(\.selector)), [
            "applyWithPolicyData:completionHandler:", "currentPolicyVersionWithCompletionHandler:",
            "drainEventsWithMax:completionHandler:", "subscribeWithClient:completionHandler:",
        ])
    }

    // MARK: Bridging

    private struct Rig {
        let raw = FakeReplyProxy()
        let errors = ErrorLog()
        let service: any WardenExtensionXPC

        init() {
            let raw = raw
            let errors = errors
            service = ReplyBridge.service(onError: { errors.append($0) }, makeProxy: { handler in
                raw.errorHandler = handler
                return raw
            })
        }
    }

    private static let invalid = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)

    func testRepliesAreForwarded() async throws {
        let rig = Rig()
        rig.raw.replies = .immediate(version: 7, data: Data("[]".utf8))
        let version = try await rig.service.apply(policyData: Data("{}".utf8))
        XCTAssertEqual(version, 7)
        let current = await rig.service.currentPolicyVersion()
        XCTAssertEqual(current, 7)
        let drained = await rig.service.drainEvents(max: 500)
        XCTAssertEqual(drained, Data("[]".utf8))
        await rig.service.subscribe(client: LiveEventSink())
        XCTAssertEqual(rig.raw.calls.count, 4)
        XCTAssertEqual(rig.raw.drainMaxes, [500])
        XCTAssertTrue(rig.errors.all.isEmpty)
        XCTAssertEqual(rig.raw.pendingCount, 0)
    }

    func testErrorReplyIsThrownUnchanged() async throws {
        let rig = Rig()
        let rejected = NSError(
            domain: WardenXPCError.domain, code: WardenXPCError.invalidPolicyCode,
            userInfo: [WardenXPCError.validationErrorsKey: ["bad rule"]]
        )
        rig.raw.replies = .immediateError(rejected)
        do {
            _ = try await rig.service.apply(policyData: Data("{}".utf8))
            XCTFail("expected the rejection")
        } catch {
            XCTAssertEqual(ExtensionLink.map(error), .invalidPolicy(["bad rule"]))
        }
    }

    /// The leak this bridge exists for: NSXPC reports a connection error and never calls the reply block.
    func testConnectionErrorResumesEveryPendingCallAndIgnoresLateReplies() async throws {
        let rig = Rig()
        rig.raw.replies = .held
        let service = rig.service
        let finished = expectation(description: "all calls returned")
        finished.expectedFulfillmentCount = 4
        let apply = Task {
            defer { finished.fulfill() }
            return try await service.apply(policyData: Data("{}".utf8))
        }
        let version = Task {
            defer { finished.fulfill() }
            return await service.currentPolicyVersion()
        }
        let drain = Task {
            defer { finished.fulfill() }
            return await service.drainEvents(max: 10)
        }
        let subscribe = Task {
            defer { finished.fulfill() }
            await service.subscribe(client: LiveEventSink())
        }
        await rig.raw.calls.wait(for: 4)
        XCTAssertEqual(rig.raw.pendingCount, 4)

        rig.raw.failConnection(Self.invalid)

        await fulfillment(of: [finished], timeout: 10) // safety net only: resumption is synchronous
        do {
            _ = try await apply.value
            XCTFail("expected the connection error")
        } catch {
            XCTAssertEqual((error as NSError).code, NSXPCConnectionInvalid)
        }
        let returnedVersion = await version.value
        XCTAssertEqual(returnedVersion, 0, "the value is ignored by ExtensionLink, whose gate onError resolved")
        let returnedData = await drain.value
        XCTAssertEqual(returnedData, Data())
        await subscribe.value
        XCTAssertEqual(rig.errors.all.map { ($0 as NSError).code }, [NSXPCConnectionInvalid])

        rig.raw.replyToHeld(version: 9, data: Data("[]".utf8)) // late replies hit spent gates
        XCTAssertEqual(rig.raw.pendingCount, 0)
    }

    func testCallsAfterAConnectionErrorFailWithoutBeingSent() async throws {
        let rig = Rig()
        rig.raw.failConnection(Self.invalid)
        do {
            _ = try await rig.service.apply(policyData: Data("{}".utf8))
            XCTFail("expected the connection error")
        } catch {
            XCTAssertEqual((error as NSError).code, NSXPCConnectionInvalid)
        }
        let version = await rig.service.currentPolicyVersion()
        XCTAssertEqual(version, 0)
        XCTAssertEqual(rig.raw.calls.count, 0)
    }

    func testUnexpectedProxyTypeFailsAtOnce() async throws {
        let errors = ErrorLog()
        let service = ReplyBridge.service(onError: { errors.append($0) }, makeProxy: { _ in NSObject() })
        do {
            _ = try await service.apply(policyData: Data("{}".utf8))
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error is XPCProxyUnavailable)
        }
        XCTAssertEqual(errors.all.count, 1)
    }
}

final class ErrorLog: Sendable {
    private let errors = Mutex<[any Error]>([])

    func append(_ error: any Error) {
        errors.withLock { $0.append(error) }
    }

    var all: [any Error] {
        errors.withLock { $0 }
    }
}

/// A raw reply-block proxy like `remoteObjectProxyWithErrorHandler` returns: on a connection error NSXPC calls the
/// error handler and never the reply blocks.
final class FakeReplyProxy: NSObject, WardenExtensionReplyXPC, Sendable {
    enum Replies {
        case immediate(version: Int64, data: Data)
        case immediateError(NSError)
        case held
    }

    private struct Held {
        var version: [@Sendable (Int64) -> Void] = []
        var apply: [@Sendable (Int64, (any Error)?) -> Void] = []
        var data: [@Sendable (Data) -> Void] = []
        var void: [@Sendable () -> Void] = []

        var count: Int {
            version.count + apply.count + data.count + void.count
        }
    }

    private struct State {
        var replies = Replies.immediate(version: 1, data: Data())
        var errorHandler: (@Sendable (any Error) -> Void)?
        var held = Held()
        var drainMaxes: [Int] = []
    }

    private let state = Mutex(State())
    let calls = CallLatch()

    var replies: Replies {
        get { state.withLock { $0.replies } }
        set { state.withLock { $0.replies = newValue } }
    }

    var errorHandler: (@Sendable (any Error) -> Void)? {
        get { state.withLock { $0.errorHandler } }
        set { state.withLock { $0.errorHandler = newValue } }
    }

    var pendingCount: Int {
        state.withLock { $0.held.count }
    }

    var drainMaxes: [Int] {
        state.withLock { $0.drainMaxes }
    }

    func failConnection(_ error: NSError) {
        errorHandler?(error)
    }

    /// Delivers every held reply (a late reply after a connection error).
    func replyToHeld(version: Int64, data: Data) {
        let held = state.withLock { state -> Held in
            defer { state.held = Held() }
            return state.held
        }
        held.version.forEach { $0(version) }
        held.apply.forEach { $0(version, nil) }
        held.data.forEach { $0(data) }
        held.void.forEach { $0() }
    }

    func apply(policyData _: Data, reply: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        switch replies {
        case let .immediate(version, _): reply(version, nil)
        case let .immediateError(error): reply(0, error)
        case .held: state.withLock { $0.held.apply.append(reply) }
        }
        calls.increment()
    }

    func currentPolicyVersion(reply: @escaping @Sendable (Int64) -> Void) {
        switch replies {
        case let .immediate(version, _): reply(version)
        case .immediateError: reply(0)
        case .held: state.withLock { $0.held.version.append(reply) }
        }
        calls.increment()
    }

    func drainEvents(max: Int, reply: @escaping @Sendable (Data) -> Void) {
        state.withLock { $0.drainMaxes.append(max) }
        switch replies {
        case let .immediate(_, data): reply(data)
        case .immediateError: reply(Data())
        case .held: state.withLock { $0.held.data.append(reply) }
        }
        calls.increment()
    }

    func subscribe(client _: any WardenClientXPC, reply: @escaping @Sendable () -> Void) {
        switch replies {
        case .immediate, .immediateError: reply()
        case .held: state.withLock { $0.held.void.append(reply) }
        }
        calls.increment()
    }
}
