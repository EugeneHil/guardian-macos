import AppKit
import SwiftUI

@main
struct WardenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var environment: AppEnvironment {
        appDelegate.environment
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverScene(environment: environment)
        } label: {
            Image(systemName: "shield.lefthalf.filled")
        }
        .menuBarExtraStyle(.window)

        Window("All events", id: WindowID.events) {
            EventsWindowView(model: environment.eventsViewModel)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Settings", id: WindowID.settings) {
            SettingsView(model: environment.settingsViewModel)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
    }
}

/// Starts the long-running services once the app has finished launching (the popover content only exists while it
/// is open, so its `.task` cannot own them).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()

    func applicationDidFinishLaunching(_: Notification) {
        environment.start()
    }
}

/// Hands the scene's `openWindow` action to the environment's window router, then shows the popover.
private struct PopoverScene: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PopoverView(model: environment.popoverViewModel)
            .onAppear { environment.windows.attach(openWindow) }
    }
}
