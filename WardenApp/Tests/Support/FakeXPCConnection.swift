import Foundation
import Synchronization

/// Scriptable stand-in for the extension's XPC service. A hanging call never replies and ignores cancellation,
/// like a reply from a dead peer that never arrives.
final class FakeExtensionService: NSObject, WardenExtensionXPC, Sendable {
    private struct State {
        var applyResult: Result<Int64, NSError> = .success(1)
        var version: Int64 = 0
        var drainData = Data("[]".utf8)
        var hangs = false
        var failsViaErrorHandler = false
        var hung: [CheckedContinuation<Void, Never>] = []
        var applied: [Data] = []
        var drainMaxes: [Int] = []
        var clients: [any WardenClientXPC] = []
    }

    private let state = Mutex(State())
    let subscribeCalls = CallLatch()
    let hungCalls = CallLatch()

    func setApplyResult(_ result: Result<Int64, NSError>) {
        state.withLock { $0.applyResult = result }
    }

    func setVersion(_ version: Int64) {
        state.withLock { $0.version = version }
    }

    func setDrainData(_ data: Data) {
        state.withLock { $0.drainData = data }
    }

    func setHangs(_ hangs: Bool) {
        state.withLock { $0.hangs = hangs }
    }

    /// Every call reports a connection error through the proxy's error handler and never replies, like NSXPC does
    /// when the Mach lookup fails or the connection is interrupted or invalidated.
    func setFailsViaErrorHandler(_ fails: Bool) {
        state.withLock { $0.failsViaErrorHandler = fails }
    }

    var failsViaErrorHandler: Bool {
        state.withLock { $0.failsViaErrorHandler }
    }

    /// Delivers the replies of every hung call (late replies).
    func releaseHung() {
        let hung = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state.hung = [] }
            return state.hung
        }
        for continuation in hung {
            continuation.resume()
        }
    }

    var applied: [Data] {
        state.withLock { $0.applied }
    }

    var drainMaxes: [Int] {
        state.withLock { $0.drainMaxes }
    }

    var clients: [any WardenClientXPC] {
        state.withLock { $0.clients }
    }

    private func hangIfScripted() async {
        let hangs = state.withLock { $0.hangs }
        guard hangs else { return }
        await hang()
    }

    /// Suspends until `releaseHung()`, ignoring cancellation.
    func hang() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { $0.hung.append(continuation) }
            hungCalls.increment()
        }
    }

    func apply(policyData: Data) async throws -> Int64 {
        state.withLock { $0.applied.append(policyData) }
        await hangIfScripted()
        return try state.withLock { $0.applyResult }.get()
    }

    func currentPolicyVersion() async -> Int64 {
        await hangIfScripted()
        return state.withLock { $0.version }
    }

    func drainEvents(max: Int) async -> Data {
        state.withLock { $0.drainMaxes.append(max) }
        await hangIfScripted()
        return state.withLock { $0.drainData }
    }

    func subscribe(client: any WardenClientXPC) async {
        state.withLock { $0.clients.append(client) }
        subscribeCalls.increment()
    }
}

final class FakeXPCSession: XPCSession {
    let fake: FakeExtensionService
    let invalidations = CallLatch()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(fake: FakeExtensionService) {
        self.fake = fake
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func service(onError: @escaping @Sendable (any Error) -> Void) -> any WardenExtensionXPC {
        FakeProxy(fake: fake, onError: onError)
    }

    func interruptions() -> AsyncStream<Void> {
        stream
    }

    func invalidate() {
        invalidations.increment()
        continuation.finish()
    }

    /// Simulates the connection's interruption handler firing.
    func interrupt() {
        continuation.yield()
    }
}

struct FakeConnectError: Error {}

/// Hands out a new `FakeXPCSession` per `connect`, using the queued services first.
final class FakeXPCConnectionProvider: XPCConnectionProviding {
    private struct State {
        var queued: [FakeExtensionService] = []
        var sessions: [FakeXPCSession] = []
        var exported: [any WardenClientXPC] = []
        var failsToConnect = false
    }

    private let state = Mutex(State())

    init(services: [FakeExtensionService] = []) {
        state.withLock { $0.queued = services }
    }

    func setFailsToConnect(_ fails: Bool) {
        state.withLock { $0.failsToConnect = fails }
    }

    var sessions: [FakeXPCSession] {
        state.withLock { $0.sessions }
    }

    var exported: [any WardenClientXPC] {
        state.withLock { $0.exported }
    }

    func connect(exporting client: any WardenClientXPC) throws -> any XPCSession {
        try state.withLock { state in
            if state.failsToConnect {
                throw FakeConnectError()
            }
            let fake = state.queued.isEmpty ? FakeExtensionService() : state.queued.removeFirst()
            let session = FakeXPCSession(fake: fake)
            state.sessions.append(session)
            state.exported.append(client)
            return session
        }
    }
}

/// A per-call proxy, like `remoteObjectProxyWithErrorHandler`: connection errors go to `onError`, not to the reply.
final class FakeProxy: NSObject, WardenExtensionXPC, Sendable {
    private let fake: FakeExtensionService
    private let onError: @Sendable (any Error) -> Void

    init(fake: FakeExtensionService, onError: @escaping @Sendable (any Error) -> Void) {
        self.fake = fake
        self.onError = onError
    }

    private func failIfScripted() async {
        guard fake.failsViaErrorHandler else { return }
        onError(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid))
        await fake.hang()
    }

    func apply(policyData: Data) async throws -> Int64 {
        await failIfScripted()
        return try await fake.apply(policyData: policyData)
    }

    func currentPolicyVersion() async -> Int64 {
        await failIfScripted()
        return await fake.currentPolicyVersion()
    }

    func drainEvents(max: Int) async -> Data {
        await failIfScripted()
        return await fake.drainEvents(max: max)
    }

    func subscribe(client: any WardenClientXPC) async {
        await failIfScripted()
        await fake.subscribe(client: client)
    }
}
