#if DEBUG
    import Foundation
    import Synchronization

    /// In-memory fakes and a pre-filled store for SwiftUI previews only.
    @MainActor
    enum PreviewFixtures {
        static let home = "/Users/me"

        /// A store fed with the given states and events; previews call `run()` in `.task` to apply them.
        static func store(
            sync: SyncState = .synced(version: 2, at: Date(timeIntervalSinceNow: -4)),
            extensionState: ExtensionState = .active,
            events: [AccessEvent] = sampleEvents
        ) -> AppStateStore {
            let syncStream = AsyncStream.makeStream(of: SyncState.self)
            let extStream = AsyncStream.makeStream(of: ExtensionState.self)
            let eventStream = AsyncStream.makeStream(of: AccessEvent.self)
            syncStream.continuation.yield(sync)
            extStream.continuation.yield(extensionState)
            for event in events {
                eventStream.continuation.yield(event)
            }
            syncStream.continuation.finish()
            extStream.continuation.finish()
            eventStream.continuation.finish()
            return AppStateStore(
                sync: syncStream.stream, extensionStates: extStream.stream, events: eventStream.stream,
                now: { Date() }
            )
        }

        static func popover(_ store: AppStateStore) -> PopoverViewModel {
            PopoverViewModel(store: store, syncNow: {}, openSettings: {}, openEvents: {}, now: { Date() }, home: home)
        }

        static func settings(_ store: AppStateStore) -> SettingsViewModel {
            SettingsViewModel(
                store: store, settings: PreviewSettingsStore(), secrets: PreviewSecretStore(),
                extensionManager: PreviewExtensionManager(), resumeSync: {}, resumeUploader: {}
            )
        }

        static func events(_ store: AppStateStore) -> EventsViewModel {
            EventsViewModel(store: store, now: { Date() }, home: home)
        }

        static let sampleEvents: [AccessEvent] = [
            event(process: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                  file: "/Users/me/proj/api/.env", age: 3600, decision: .allow),
            event(process: "/usr/bin/python3", file: "/Users/me/proj/api/secrets.txt", age: 600, decision: .deny),
            event(process: "/bin/cat", file: "/Users/me/.ssh/id_ed25519", age: 12, decision: .deny),
        ]

        private static func event(
            process: String, file: String, age: TimeInterval, decision: AccessDecision
        ) -> AccessEvent {
            AccessEvent(
                id: UUID(), timestamp: Date(timeIntervalSinceNow: -age),
                process: ProcessIdentity(path: process, signingId: "", teamId: ""), responsible: nil,
                file: file, decision: decision, ruleId: decision == .deny ? "r1" : nil
            )
        }
    }

    private final class PreviewSettingsStore: SettingsStoring, Sendable {
        private let state = Mutex(AgentSettings(serverURL: URL(string: "https://warden.example.com"), spkiPin: ""))

        func load() -> AgentSettings {
            state.withLock { $0 }
        }

        func save(_ settings: AgentSettings) {
            state.withLock { $0 = settings }
        }
    }

    private struct PreviewSecretStore: SecretStoring {
        func token() async throws -> String? {
            nil
        }

        func saveToken(_: String) async throws {}

        func deleteToken() async throws {}
    }

    private struct PreviewExtensionManager: ExtensionManaging {
        let states = AsyncStream.makeStream(of: ExtensionState.self).stream

        func refresh() async {}

        func install() async {}

        func uninstall() async {}
    }
#endif
