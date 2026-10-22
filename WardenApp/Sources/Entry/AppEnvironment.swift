import AppKit
import SwiftUI

enum WindowID {
    static let events = "events"
    static let settings = "settings"
}

/// Opens the app's windows from the menu bar popover. Warden is an accessory app (LSUIElement), so it activates
/// itself first; otherwise the window opens behind the frontmost app.
@MainActor
final class WindowRouter {
    private var openWindow: OpenWindowAction?

    func attach(_ action: OpenWindowAction) {
        openWindow = action
    }

    func show(_ id: String) {
        NSApp.activate()
        openWindow?(id: id)
    }
}

/// Composition root: builds the real object graph once and owns the long-running services.
///
/// Stream ownership (every `AsyncStream` has exactly one consumer): `PolicySyncService.states` and
/// `ExtensionManager.states` go to `AppStateStore`; `ExtensionLink.liveEvents()` is called once for the store and
/// once for `BlockNotifier` (each call returns an independent stream). `EventUploader` drains separately.
@MainActor
final class AppEnvironment {
    let store: AppStateStore
    let popoverViewModel: PopoverViewModel
    let settingsViewModel: SettingsViewModel
    let eventsViewModel: EventsViewModel
    let windows: WindowRouter

    private let sync: PolicySyncService
    private let uploader: EventUploader
    private let extensionManager: ExtensionManager
    private let notifier: BlockNotifier
    private let notifierEvents: AsyncStream<AccessEvent>
    private var services: Task<Void, Never>?

    init() {
        let now: @Sendable () -> Date = { Date() }
        let settingsStore = UserDefaultsSettingsStore()
        let loadSettings: @Sendable () -> AgentSettings = { settingsStore.load() }
        // One cache shared by the API and the settings window, so a saved token replaces the cached one.
        let secrets = CachedSecretStore(base: KeychainSecretStore(), clock: ContinuousClock())
        let api = HTTPAgentAPI(
            settings: loadSettings, secrets: secrets, transport: PinnedURLSession(settings: loadSettings)
        )
        let link = ExtensionLink(provider: MachServiceConnector(), clock: ContinuousClock())
        let sync = PolicySyncService(api: api, link: link, clock: ContinuousClock(), now: now)
        let uploader = EventUploader(api: api, link: link, clock: ContinuousClock())
        let extensionManager = ExtensionManager()
        let windows = WindowRouter()
        let store = AppStateStore(
            sync: sync.states, extensionStates: extensionManager.states, events: link.liveEvents(), now: now
        )

        self.store = store
        self.windows = windows
        self.sync = sync
        self.uploader = uploader
        self.extensionManager = extensionManager
        notifier = BlockNotifier(poster: UserNotificationPoster())
        notifierEvents = link.liveEvents()
        popoverViewModel = PopoverViewModel(
            store: store, syncNow: { await sync.syncNow() },
            openSettings: { [windows] in windows.show(WindowID.settings) },
            openEvents: { [windows] in windows.show(WindowID.events) },
            now: now
        )
        settingsViewModel = SettingsViewModel(
            store: store, settings: settingsStore, secrets: secrets, extensionManager: extensionManager,
            resumeSync: { await sync.resume() }, resumeUploader: { await uploader.resume() }
        )
        eventsViewModel = EventsViewModel(store: store, now: now)
    }

    /// Starts every long-running service under one parent task, which ends when the app is about to terminate
    /// (or `stop()` is called). Calling it again while running does nothing.
    func start() {
        guard services == nil else { return }
        let sync = sync
        let uploader = uploader
        let store = store
        let manager = extensionManager
        let notifier = notifier
        let notifierEvents = notifierEvents
        services = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await sync.run() }
                group.addTask { await uploader.run() }
                group.addTask { await store.run() }
                group.addTask { await notifier.run(events: notifierEvents) }
                group.addTask { await notifier.poster.requestAuthorization() }
                group.addTask { await manager.refresh() }
                await Self.untilTermination()
                group.cancelAll()
            }
        }
    }

    func stop() {
        services?.cancel()
    }

    /// Returns when the app posts `willTerminateNotification` or the calling task is cancelled.
    private static func untilTermination() async {
        for await _ in NotificationCenter.default.notifications(named: NSApplication.willTerminateNotification) {
            return
        }
    }
}
