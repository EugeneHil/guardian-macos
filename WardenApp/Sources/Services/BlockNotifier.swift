import Foundation

/// Posts a notification for every blocked open seen on the live event stream.
/// Live delivery is best-effort (see `ExtensionLinking.liveEvents`), so some blocks may never be notified.
struct BlockNotifier: Sendable {
    let poster: any NotificationPosting

    /// Runs until `events` finishes. Only `.deny` means blocked: an `.allow` may still carry a rule id (a late deny
    /// overridden by the extension's watchdog).
    func run(events: AsyncStream<AccessEvent>) async {
        for await event in events where event.decision == .deny {
            await poster.postBlock(
                process: BlockMessage.name(of: event.process.path), file: BlockMessage.name(of: event.file)
            )
        }
    }
}
