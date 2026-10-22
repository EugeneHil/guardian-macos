import Foundation
import os

enum SyncState: Equatable, Sendable {
    case notConfigured
    case idle
    // swiftlint:disable:next identifier_name
    case synced(version: Int64, at: Date)
    case unreachable(lastVersion: Int64?)
    case unauthorized
    case throttled(until: Date)
    case extensionUnavailable(version: Int64)
}

/// Polls the server for the policy and keeps the extension's copy up to date.
/// The last good policy stays enforced whenever the server or the extension misbehaves.
actor PolicySyncService {
    nonisolated let states: AsyncStream<SyncState>
    private(set) var state: SyncState = .idle

    private let api: any AgentAPI
    private let link: any ExtensionLinking
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let interval: Duration
    private let continuation: AsyncStream<SyncState>.Continuation
    private let log = Logger(subsystem: "com.warden.app", category: "policy-sync")

    private var etag: String?
    private var appliedVersion: Int64?
    private var lastBody: Data?
    /// ETag of a policy the extension refused; it is not pushed again until the server sends another one.
    private var rejectedETag: String?
    private var paused = false
    private var syncing = false
    private var nextDelay: Duration?

    init(
        api: any AgentAPI, link: any ExtensionLinking, clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date, interval: Duration = .seconds(10)
    ) {
        self.api = api
        self.link = link
        self.clock = clock
        self.now = now
        self.interval = interval
        (states, continuation) = AsyncStream.makeStream(of: SyncState.self)
        continuation.yield(.idle)
    }

    deinit {
        continuation.finish()
    }

    /// Polls until cancelled. After `unauthorized` it stops contacting the server until `resume()`.
    func run() async {
        while !Task.isCancelled {
            if !paused {
                await syncOnce()
            }
            let delay = nextDelay ?? interval
            nextDelay = nil
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    func syncNow() async {
        await syncOnce()
    }

    /// Lets the polling loop contact the server again at its next tick.
    func resume() {
        paused = false
    }

    private func set(_ newState: SyncState) {
        guard newState != state else { return }
        state = newState
        continuation.yield(newState)
    }

    private func syncOnce() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            switch try await api.fetchPolicy(etag: etag) {
            case let .modified(body, newETag, version):
                paused = false
                await handleModified(body: body, etag: newETag, version: version)
            case .notModified:
                paused = false
                await handleNotModified()
            }
        } catch let error as AgentAPIError {
            handle(error)
        } catch {
            if !(error is CancellationError) {
                set(.unreachable(lastVersion: appliedVersion))
            }
        }
    }

    private func handleModified(body: Data, etag newETag: String, version: Int64) async {
        if newETag == rejectedETag {
            set(.extensionUnavailable(version: appliedVersion ?? 0))
            return
        }
        await push(body: body, etag: newETag, serverVersion: version)
    }

    private func handleNotModified() async {
        guard let version = appliedVersion, let body = lastBody else {
            return
        }
        do {
            let current = try await link.currentPolicyVersion()
            if current != version {
                log.info("extension policy version differs from the last applied one, re-pushing")
                await push(body: body, etag: etag, serverVersion: version)
                return
            }
            set(.synced(version: version, at: now()))
        } catch {
            if error is CancellationError {
                return
            }
            etag = nil
            set(.extensionUnavailable(version: version))
        }
    }

    private func push(body: Data, etag newETag: String?, serverVersion: Int64) async {
        do {
            let applied = try await link.apply(policy: body)
            etag = newETag
            appliedVersion = applied
            lastBody = body
            rejectedETag = nil
            set(.synced(version: applied, at: now()))
        } catch let ExtensionLinkError.invalidPolicy(reasons) {
            log.error("extension rejected the policy (\(reasons.count) problems)")
            rejectedETag = newETag
            set(.extensionUnavailable(version: appliedVersion ?? 0))
        } catch is CancellationError {
            return
        } catch {
            etag = nil
            set(.extensionUnavailable(version: serverVersion))
        }
    }

    private func handle(_ error: AgentAPIError) {
        switch error {
        case .unauthorized:
            paused = true
            set(.unauthorized)
        case let .throttled(retryAfter):
            nextDelay = retryAfter
            let seconds = Double(retryAfter.components.seconds)
            set(.throttled(until: now().addingTimeInterval(seconds)))
        case .notConfigured:
            set(.notConfigured)
        case .invalidBatch, .payloadTooLarge, .server, .transport, .pinMismatch, .malformedResponse:
            set(.unreachable(lastVersion: appliedVersion))
        }
    }
}
