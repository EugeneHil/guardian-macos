import Foundation
import os

/// Durable copy of the events that were drained from the extension but not yet accepted by the server.
protocol PendingEventStoring: Sendable {
    func load() throws -> [AccessEvent]
    /// Replaces the stored events; an empty array leaves nothing on disk.
    func save(_ events: [AccessEvent]) throws
}

/// Default for callers that do not persist (tests, previews).
struct NoPendingEventStore: PendingEventStoring {
    func load() throws -> [AccessEvent] {
        []
    }

    func save(_: [AccessEvent]) throws {}
}

/// Keeps the pending events in one JSON array file under Application Support/<bundle id>.
///
/// Events contain file paths, so the directory is 0700 and the file 0600. A JSON array (not JSON Lines) is used
/// because every save rewrites the whole file atomically anyway, so there is no partial append to recover from,
/// and the array is at most `maxPending` (5000) small objects.
struct FileEventStore: PendingEventStoring {
    static let fileName = "pending-events.json"

    let fileURL: URL
    private let directory: URL
    private let log = Logger(subsystem: BundleIDs.app, category: "event-store")

    init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// The store in the app's own Application Support directory.
    static func standard() -> FileEventStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return FileEventStore(directory: base.appendingPathComponent(BundleIDs.app, isDirectory: true))
    }

    /// A missing file is "no events". A corrupt or unreadable one is logged (never its content) and also treated
    /// as empty: losing the backlog is better than failing to start.
    func load() throws -> [AccessEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([AccessEvent].self, from: Data(contentsOf: fileURL))
        } catch {
            log.error("pending events file is unreadable or corrupt, starting empty")
            return []
        }
    }

    func save(_ events: [AccessEvent]) throws {
        let manager = FileManager.default
        if events.isEmpty {
            if manager.fileExists(atPath: fileURL.path) {
                try manager.removeItem(at: fileURL)
            }
            return
        }
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(events)
        // Temporary file in the same directory, created 0600, then renamed over the target (atomic).
        let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }
}

/// Runs `flush` but returns after `timeout` at the latest, even when `flush` ignores cancellation and never
/// returns (the abandoned flush is cancelled and left to finish on its own). Used to bound the flush on quit.
func flushWithTimeout<C: Clock>(
    _ timeout: Duration, clock: C, flush: @escaping @Sendable () async -> Void
) async where C.Duration == Duration {
    let (finished, signal) = AsyncStream.makeStream(of: Void.self)
    let flushTask = Task {
        await flush()
        signal.yield()
    }
    let timer = Task {
        try? await clock.sleep(for: timeout)
        signal.yield()
    }
    for await _ in finished {
        break
    }
    flushTask.cancel()
    timer.cancel()
    await timer.value
}
