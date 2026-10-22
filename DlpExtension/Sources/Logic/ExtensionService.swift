import Foundation

/// Fans live events out to the subscribed app clients. Each client has its own bounded queue and pump task, so a
/// peer that never answers only loses its own (best-effort) live events; `drainEvents` is the reliable path.
actor ClientHub {
    private struct Entry {
        let continuation: AsyncStream<Data>.Continuation
        let pump: Task<Void, Never>
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    var count: Int {
        entries.count
    }

    /// Replaces any client already registered under the same key.
    func add(key: ObjectIdentifier, client: any WardenClientXPC) {
        remove(key: key)
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(100))
        let pump = Task {
            for await data in stream {
                await client.eventRecorded(data)
            }
        }
        entries[key] = Entry(continuation: continuation, pump: pump)
    }

    func remove(key: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.continuation.finish()
        entry.pump.cancel()
    }

    func broadcast(_ event: AccessEvent) {
        guard !entries.isEmpty, let data = try? XPCCoding.encode(event) else { return }
        for entry in entries.values {
            entry.continuation.yield(data)
        }
    }

    deinit {
        for entry in entries.values {
            entry.continuation.finish()
            entry.pump.cancel()
        }
    }
}

/// Exported once per connection so `subscribe` knows which connection a client belongs to.
private final class ConnectionEndpoint: NSObject, WardenExtensionXPC, Sendable {
    private let service: ExtensionService
    private let key: ObjectIdentifier

    init(service: ExtensionService, key: ObjectIdentifier) {
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

    func subscribe(client: any WardenClientXPC) async {
        await service.subscribe(client: client, connectionKey: key)
    }
}

/// XPC server of the system extension. Calls are plain async members so tests can drive them directly.
final class ExtensionService: NSObject, WardenExtensionXPC, NSXPCListenerDelegate, Sendable {
    private let policy: PolicyController
    private let events: EventQueue
    private let hub = ClientHub()
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
                domain: WardenXPCError.domain, code: WardenXPCError.invalidPolicyCode,
                userInfo: [
                    NSLocalizedDescriptionKey: lines.joined(separator: "; "),
                    WardenXPCError.validationErrorsKey: lines,
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

    func subscribe(client: any WardenClientXPC) async {
        // NSXPCConnection.current() is unavailable in async contexts; real connections go through
        // `ConnectionEndpoint`, which supplies the connection key.
        await subscribe(client: client, connectionKey: ObjectIdentifier(client))
    }

    /// One client per connection: subscribing again on the same connection replaces the previous client.
    func subscribe(client: any WardenClientXPC, connectionKey: ObjectIdentifier) async {
        await hub.add(key: connectionKey, client: client)
    }

    func removeClients(connectionKey: ObjectIdentifier) async {
        await hub.remove(key: connectionKey)
    }

    func subscriberCount() async -> Int {
        await hub.count
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let exported = NSXPCInterface(with: WardenExtensionXPC.self)
        exported.setInterface(
            NSXPCInterface(with: WardenClientXPC.self), for: #selector(WardenExtensionXPC.subscribe(client:)),
            argumentIndex: 0, ofReply: false
        )
        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: WardenClientXPC.self)
        connection.setCodeSigningRequirement(Self.peerRequirement())
        let key = ObjectIdentifier(connection)
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
