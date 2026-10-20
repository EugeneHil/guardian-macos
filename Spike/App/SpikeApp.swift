// THROWAWAY SPIKE: minimal host app that activates / deactivates the system extension.
import SwiftUI
import SystemExtensions

final class Activator: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "idle"
    private let identifier = "dev.warden.spike.ext"

    func activate() {
        status = "requesting activation…"
        OSSystemExtensionManager.shared.submitRequest(
            OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main).withDelegate(self))
    }

    func deactivate() {
        status = "requesting deactivation…"
        OSSystemExtensionManager.shared.submitRequest(
            OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main).withDelegate(self))
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status = "finished: \(result.rawValue) (0 = completed, 1 = needs reboot)"
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { status = "FAILED: \(error)" }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { status = "needs approval in System Settings" }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}

extension OSSystemExtensionRequest {
    func withDelegate(_ delegate: OSSystemExtensionRequestDelegate) -> OSSystemExtensionRequest {
        self.delegate = delegate
        return self
    }
}

@main
struct SpikeApp: App {
    @StateObject private var activator = Activator()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Button("Activate") { activator.activate() }
                Button("Deactivate") { activator.deactivate() }
                Text(activator.status).textSelection(.enabled)
            }
            .padding(24)
            .frame(minWidth: 420)
        }
    }
}
