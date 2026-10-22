import Foundation
import Synchronization

/// Builds access events for view-model tests.
enum EventFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func make(
        id: UUID = UUID(), decision: AccessDecision = .deny, ruleId: String? = "r1", age: TimeInterval = 12,
        file: String = "/Users/eugene/proj/secret.txt"
    ) -> AccessEvent {
        AccessEvent(
            id: id,
            timestamp: now.addingTimeInterval(-age),
            process: ProcessIdentity(path: "/usr/bin/cat", signingId: "", teamId: ""),
            responsible: nil,
            file: file,
            decision: decision,
            ruleId: ruleId
        )
    }
}

/// Records saved settings.
final class RecordingSettingsStore: SettingsStoring, Sendable {
    private let state: Mutex<AgentSettings>
    let saveCalls = CallLatch()

    init(_ initial: AgentSettings = AgentSettings(serverURL: nil, spkiPin: "")) {
        state = Mutex(initial)
    }

    func load() -> AgentSettings {
        state.withLock { $0 }
    }

    func save(_ settings: AgentSettings) {
        state.withLock { $0 = settings }
        saveCalls.increment()
    }
}

/// A secret store whose writes fail.
struct RejectingSecretStore: SecretStoring {
    struct Failure: Error {}

    var storedToken: String?

    func token() async throws -> String? {
        storedToken
    }

    func saveToken(_: String) async throws {
        throw Failure()
    }

    func deleteToken() async throws {}
}

/// Counts install/uninstall/refresh calls.
final class FakeExtensionManager: ExtensionManaging, Sendable {
    let installCalls = CallLatch()
    let uninstallCalls = CallLatch()
    let refreshCalls = CallLatch()
    nonisolated let states: AsyncStream<ExtensionState>

    init() {
        states = AsyncStream.makeStream(of: ExtensionState.self).stream
    }

    func refresh() async {
        refreshCalls.increment()
    }

    func install() async {
        installCalls.increment()
    }

    func uninstall() async {
        uninstallCalls.increment()
    }
}

/// Controls the four streams an `AppStateStore` consumes.
struct StoreHarness {
    let sync = AsyncStream.makeStream(of: SyncState.self)
    let ext = AsyncStream.makeStream(of: ExtensionState.self)
    let events = AsyncStream.makeStream(of: AccessEvent.self)
    let drained = AsyncStream.makeStream(of: AccessEvent.self)

    @MainActor
    func makeStore() -> AppStateStore {
        AppStateStore(
            sync: sync.stream, extensionStates: ext.stream, events: events.stream, drained: drained.stream,
            now: { EventFixture.now }
        )
    }

    /// Finishes all streams and waits until the store has consumed everything yielded so far.
    @MainActor
    func settle(_ store: AppStateStore) async {
        sync.continuation.finish()
        ext.continuation.finish()
        events.continuation.finish()
        drained.continuation.finish()
        await store.run()
    }
}

/// A secret store whose `saveToken` suspends until `release()` is called.
final class GatedSecretStore: SecretStoring, Sendable {
    let entered = CallLatch()
    let saved = CallLatch()
    private let gate = AsyncStream.makeStream(of: Void.self)

    func token() async throws -> String? {
        nil
    }

    func saveToken(_: String) async throws {
        entered.increment()
        for await _ in gate.stream {
            break
        }
        saved.increment()
    }

    func deleteToken() async throws {}

    func release() {
        gate.continuation.yield()
    }
}
