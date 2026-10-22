import Foundation

/// Fans live events out to the subscribed app clients.
private actor ClientHub {
    private var clients: [any WardenClientXPC] = []

    func add(_ client: any WardenClientXPC) {
        clients.append(client)
    }

    func broadcast(_ event: AccessEvent) async {
        guard !clients.isEmpty, let data = try? XPCCoding.encode(event) else { return }
        for client in clients {
            await client.eventRecorded(data)
        }
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
                domain: WardenXPCError.domain, code: 1,
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
        await hub.add(client)
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
        connection.exportedObject = self
        connection.resume()
        return true
    }
}
