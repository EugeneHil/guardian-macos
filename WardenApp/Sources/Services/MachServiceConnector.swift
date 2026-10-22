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

struct XPCProxyUnavailable: Error {}

/// Stand-in when `NSXPCConnection` hands out a proxy of an unexpected type: every call reports `onError` at once
/// (the gate is resolved by then, so the values returned afterwards are ignored).
private final class UnavailableService: NSObject, WardenExtensionXPC, Sendable {
    private let onError: @Sendable (any Error) -> Void

    init(onError: @escaping @Sendable (any Error) -> Void) {
        self.onError = onError
    }

    func apply(policyData _: Data) async throws -> Int64 {
        onError(XPCProxyUnavailable())
        throw XPCProxyUnavailable()
    }

    func currentPolicyVersion() async -> Int64 {
        onError(XPCProxyUnavailable())
        return 0
    }

    func drainEvents(max _: Int) async -> Data {
        onError(XPCProxyUnavailable())
        return Data()
    }

    func subscribe(client _: any WardenClientXPC) async {
        onError(XPCProxyUnavailable())
    }
}

/// `@unchecked Sendable`: `NSXPCConnection` is thread-safe but not annotated `Sendable` by the SDK.
private final class MachXPCSession: XPCSession, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let events: AsyncStream<Void>

    init(client: any WardenClientXPC) {
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
        connection.resume()
    }

    func service(onError: @escaping @Sendable (any Error) -> Void) -> any WardenExtensionXPC {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(onError) as? any WardenExtensionXPC else {
            return UnavailableService(onError: onError)
        }
        return proxy
    }

    func interruptions() -> AsyncStream<Void> {
        events
    }

    func invalidate() {
        connection.invalidate()
    }
}
