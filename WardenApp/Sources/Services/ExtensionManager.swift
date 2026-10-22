import Foundation
import os
import SystemExtensions

protocol ExtensionManaging: Sendable {
    /// Queries the installed extension's properties.
    func refresh() async
    func install() async
    func uninstall() async
    nonisolated var states: AsyncStream<ExtensionState> { get }
}

/// Runs `OSSystemExtensionRequest`s and publishes the resulting `ExtensionState` (see `ExtensionState.reduce`).
/// Boundary: the request delegate is verified in the VM only; the state logic is unit-tested through the reducer.
actor ExtensionManager: ExtensionManaging {
    /// Single consumer (an `AsyncStream`): the one view model that shows the extension state.
    nonisolated let states: AsyncStream<ExtensionState>
    private let continuation: AsyncStream<ExtensionState>.Continuation
    private var state: ExtensionState = .unknown
    private let log = Logger(subsystem: "com.warden.app", category: "extension")

    init() {
        (states, continuation) = AsyncStream.makeStream(of: ExtensionState.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(.unknown)
    }

    deinit {
        continuation.finish()
    }

    func refresh() async {
        await run(.properties)
    }

    func install() async {
        await run(.activation)
    }

    func uninstall() async {
        await run(.deactivation)
    }

    /// An activation waiting for approval stays pending until the user decides, so this may suspend for long.
    private func run(_ kind: RequestKind) async {
        let delegate = RequestDelegate(kind: kind)
        // The delegate queue is required by the API; callbacks only yield into the delegate's stream.
        let request = switch kind {
        case .activation:
            OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: BundleIDs.ext, queue: .main)
        case .deactivation:
            OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: BundleIDs.ext, queue: .main)
        case .properties:
            OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: BundleIDs.ext, queue: .main)
        }
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
        for await event in delegate.events {
            if case let .failed(code) = event {
                log.error("system extension request failed with code \(code, privacy: .public)")
            }
            state = ExtensionState.reduce(state, event: event)
            continuation.yield(state)
        }
        // `request.delegate` is weak: this use keeps the delegate alive until its stream has finished.
        withExtendedLifetime(delegate) {}
    }
}

/// Turns delegate callbacks into `ExtensionRequestEvent`s; the stream finishes with the request's final outcome.
private final class RequestDelegate: NSObject, OSSystemExtensionRequestDelegate, Sendable {
    let events: AsyncStream<ExtensionRequestEvent>
    private let continuation: AsyncStream<ExtensionRequestEvent>.Continuation
    private let kind: RequestKind

    init(kind: RequestKind) {
        self.kind = kind
        (events, continuation) = AsyncStream.makeStream(of: ExtensionRequestEvent.self)
    }

    func request(
        _: OSSystemExtensionRequest, actionForReplacingExtension _: OSSystemExtensionProperties,
        withExtension _: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
        continuation.yield(.needsApproval)
    }

    func request(_: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if let event = ExtensionRequestEvent.finished(kind, rebootNeeded: result == .willCompleteAfterReboot) {
            continuation.yield(event)
        }
        continuation.finish()
    }

    func request(_: OSSystemExtensionRequest, didFailWithError error: any Error) {
        continuation.yield(.failed(code: (error as NSError).code))
        continuation.finish()
    }

    func request(_: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        if properties.contains(where: { $0.isEnabled && !$0.isUninstalling }) {
            continuation.yield(.propertiesActive(true))
        } else if properties.contains(where: \.isAwaitingUserApproval) {
            continuation.yield(.needsApproval)
        } else {
            continuation.yield(.propertiesActive(false))
        }
        continuation.finish()
    }
}
