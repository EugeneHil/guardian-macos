import SwiftUI

@main
struct WardenApp: App {
    private let extensionManager = ExtensionManager()

    var body: some Scene {
        MenuBarExtra("Warden", systemImage: "shield") {
            // TEMPORARY (Task 9/13 VM smoke gate): replaced by the real menu in Task 16.
            Button("Install extension") {
                Task { await extensionManager.install() }
            }
            Button("Uninstall extension") {
                Task { await extensionManager.uninstall() }
            }
        }
    }
}
