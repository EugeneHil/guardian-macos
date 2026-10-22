import Foundation

/// Boundary: the only `NSXPCConnection` code in the app. Its handlers are bridged to an `AsyncStream`; everything
/// else lives in `ExtensionLink` and is tested with fakes. Verified in the VM only.
struct MachServiceConnector: XPCConnectionProviding {
    /// The extension is ad-hoc signed (ADR-0001), so only its identifier can be pinned.
    static func peerRequirement() -> String {
        #"identifier "\#(BundleIDs.ext)""#
    }

    func connect(exporting client: any WardenClientXPC) -> any XPCSession {
        MachXPCSession(client: client)
    }
}

/// `@unchecked Sendable`: `NSXPCConnection` is thread-safe but not annotated `Sendable` by the SDK.
private final class MachXPCSession: XPCSession, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let events: AsyncStream<Void>

    init(client: any WardenClientXPC) {
        connection = NSXPCConnection(machServiceName: BundleIDs.machService, options: .privileged)
        // The reply-block mirror, not `WardenExtensionXPC` itself: see `WardenExtensionReplyXPC`.
        let remote = NSXPCInterface(with: WardenExtensionReplyXPC.self)
        remote.setInterface(
            NSXPCInterface(with: WardenClientXPC.self),
            for: #selector(WardenExtensionReplyXPC.subscribe(client:reply:)),
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
        connection.resume()
    }

    func service(onError: @escaping @Sendable (any Error) -> Void) -> any WardenExtensionXPC {
        ReplyBridge.service(onError: onError) { connection.remoteObjectProxyWithErrorHandler($0) }
    }

    func interruptions() -> AsyncStream<Void> {
        events
    }

    func invalidate() {
        connection.invalidate()
    }
}
