import Foundation

/// Boundary: the only `NSXPCConnection` code in the app. Its handlers are bridged to an `AsyncStream`; everything
/// else lives in `ExtensionLink` and is tested with fakes. Verified in the VM only.
struct MachServiceConnector: XPCConnectionProviding {
    /// The extension is ad-hoc signed (ADR-0001), so only its identifier can be pinned.
    static func peerRequirement() -> String {
        #"identifier "\#(BundleIDs.ext)""#
    }

    func connect(exporting client: any WardenClientXPC) throws -> any XPCSession {
        try MachXPCSession(client: client)
    }
}

struct XPCProxyUnavailable: Error {}

/// `@unchecked Sendable`: `NSXPCConnection` is thread-safe but not annotated `Sendable` by the SDK.
private final class MachXPCSession: XPCSession, @unchecked Sendable {
    let service: any WardenExtensionXPC
    private let connection: NSXPCConnection
    private let events: AsyncStream<Void>

    init(client: any WardenClientXPC) throws {
        connection = NSXPCConnection(machServiceName: BundleIDs.machService, options: .privileged)
        let remote = NSXPCInterface(with: WardenExtensionXPC.self)
        remote.setInterface(
            NSXPCInterface(with: WardenClientXPC.self), for: #selector(WardenExtensionXPC.subscribe(client:)),
            argumentIndex: 0, ofReply: false
        )
        connection.remoteObjectInterface = remote
        connection.exportedInterface = NSXPCInterface(with: WardenClientXPC.self)
        connection.exportedObject = client
        connection.setCodeSigningRequirement(MachServiceConnector.peerRequirement())
        let (events, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.events = events
        connection.interruptionHandler = { continuation.yield() }
        connection.invalidationHandler = {
            continuation.yield()
            continuation.finish()
        }
        // Errors surface as failed replies of the pending calls; the handler itself has nothing to add.
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? any WardenExtensionXPC else {
            connection.invalidate()
            throw XPCProxyUnavailable()
        }
        service = proxy
        connection.resume()
    }

    func interruptions() -> AsyncStream<Void> {
        events
    }

    func invalidate() {
        connection.invalidate()
    }
}
