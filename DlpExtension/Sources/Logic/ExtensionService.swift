import Foundation
import Synchronization

/// Fans live events out to the subscribed app clients. `eventRecorded` is fire-and-forget, so a call returns at once
/// and a dead peer cannot stall the hub; `drainEvents` is the reliable path.
actor ClientHub {
    private var clients: [UInt64: any GuardianClientXPC] = [:]
    /// Connections that already went away: a late `add` for one of them is ignored.
    private var closed: Set<UInt64> = []

    var count: Int {
        clients.count
    }

    /// Replaces any client already registered under the same key.
    func add(key: UInt64, client: any GuardianClientXPC) {
        guard !closed.contains(key) else { return }
        clients[key] = client
    }

    func remove(key: UInt64) {
        closed.insert(key)
        clients[key] = nil
    }

    func broadcast(_ event: AccessEvent) {
        guard !clients.isEmpty, let data = try? XPCCoding.encode(event) else { return }
        for client in clients.values {
            client.eventRecorded(data)
        }
    }
}

/// Exported once per connection so `subscribe` knows which connection a client belongs to.
private final class ConnectionEndpoint: NSObject, GuardianExtensionXPC, Sendable {
    private let service: ExtensionService
    private let key: UInt64

    init(service: ExtensionService, key: UInt64) {
        self.service = service
        self.key = key
    }

    func apply(policyData: Data) async throws -> Int64 {
        try await service.apply(policyData: policyData)
    }

    func currentPolicyVersion() async -> Int64 {
        await service.currentPolicyVersion()
    }

    func drainEvents(max: Int) async -> Data {
        await service.drainEvents(max: max)
    }

    func subscribe(client: any GuardianClientXPC) async {
        await service.subscribe(client: client, connectionKey: key)
    }
}

/// XPC server of the system extension. Calls are plain async members so tests can drive them directly.
final class ExtensionService: NSObject, GuardianExtensionXPC, NSXPCListenerDelegate, Sendable {
    private let policy: PolicyController
    private let events: EventQueue
    private let hub = ClientHub()
    private let lastConnectionID = Mutex<UInt64>(0)
    /// The only consumer of `EventQueue.updates`. Started at init so events recorded before the first subscriber are
    /// consumed (and dropped from the live path) instead of piling up; they stay available through `drainEvents`.
    private let forwarder: Task<Void, Never>

    init(policy: PolicyController, events: EventQueue) {
        self.policy = policy
        self.events = events
        let hub = hub
        let updates = events.updates
        forwarder = Task {
            for await event in updates {
                await hub.broadcast(event)
            }
        }
        super.init()
    }

    deinit {
        forwarder.cancel()
    }

    static func peerRequirement() -> String {
        #"identifier "\#(BundleIDs.app)""#
    }

    func apply(policyData: Data) async throws -> Int64 {
        do {
            return try await policy.apply(policyData)
        } catch let PolicyApplyError.invalid(lines) {
            throw NSError(
                domain: GuardianXPCError.domain, code: GuardianXPCError.invalidPolicyCode,
                userInfo: [
                    NSLocalizedDescriptionKey: lines.joined(separator: "; "),
                    GuardianXPCError.validationErrorsKey: lines,
                ]
            )
        }
    }

    func currentPolicyVersion() async -> Int64 {
        await policy.currentVersion()
    }

    func drainEvents(max: Int) async -> Data {
        let batch = await events.drain(max: max)
        return (try? JSONEncoder.xpc.encode(batch)) ?? Data("[]".utf8)
    }

    func subscribe(client: any GuardianClientXPC) async {
        // NSXPCConnection.current() is unavailable in async contexts; real connections go through
        // `ConnectionEndpoint`, which supplies its connection id. Direct callers get a fresh id.
        await subscribe(client: client, connectionKey: nextConnectionID())
    }

    /// One client per connection: subscribing again on the same connection replaces the previous client.
    func subscribe(client: any GuardianClientXPC, connectionKey: UInt64) async {
        await hub.add(key: connectionKey, client: client)
    }

    /// Monotonic id for an accepted connection.
    func nextConnectionID() -> UInt64 {
        lastConnectionID.withLock {
            $0 += 1
            return $0
        }
    }

    func removeClients(connectionKey: UInt64) async {
        await hub.remove(key: connectionKey)
    }

    func subscriberCount() async -> Int {
        await hub.count
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let exported = NSXPCInterface(with: GuardianExtensionXPC.self)
        exported.setInterface(
            NSXPCInterface(with: GuardianClientXPC.self), for: #selector(GuardianExtensionXPC.subscribe(client:)),
            argumentIndex: 0, ofReply: false
        )
        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: GuardianClientXPC.self)
        connection.setCodeSigningRequirement(Self.peerRequirement())
        let key = nextConnectionID()
        connection.exportedObject = ConnectionEndpoint(service: self, key: key)
        let drop: @Sendable () -> Void = { [self] in
            Task { await removeClients(connectionKey: key) }
        }
        connection.invalidationHandler = drop
        connection.interruptionHandler = drop
        connection.resume()
        return true
    }
}
