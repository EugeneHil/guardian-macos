import EndpointSecurity
import Foundation
import os
import Synchronization

enum EndpointSecurityClientError: Error {
    case newClient(es_new_client_result_t)
    case auditToken(kern_return_t)
    case mute
    case subscribe
}

/// The `es_client_t` handle together with one retained message. The handle is immutable after creation and
/// Endpoint Security allows responding/releasing from any thread; the message stays valid until released.
private struct RetainedMessage: @unchecked Sendable {
    let client: OpaquePointer
    let message: UnsafePointer<es_message_t>
    let log: Logger

    /// Answers and releases; `OpenCoordinator` guarantees exactly one call per message.
    func respond(_ response: OpenResponse) {
        // Candidates are never cached: their verdict depends on the policy and the responsible process.
        let flags: UInt32 = response == .allow ? UInt32.max : 0
        let result = es_respond_flags_result(client, message, flags, false)
        es_release_message(message)
        if result != ES_RESPOND_RESULT_SUCCESS {
            log.error("es_respond_flags_result failed: \(result.rawValue, privacy: .public)")
        }
    }
}

/// Everything the synchronous handler needs besides the client and the message.
private struct HandlerContext: Sendable {
    let coordinator: OpenCoordinator
    let cache: CacheClearScheduler
    let timebase: (numer: UInt32, denom: UInt32)
    let log: Logger
}

/// Holds the `es_client_t` once it exists. The lock serializes the kernel calls made through it (cache clears from
/// the scheduler task, deletion) against clearing the handle on teardown.
private final class ClientSlot: Sendable {
    // @unchecked: an opaque C handle; Endpoint Security client calls may be made from any thread.
    private struct Handle: @unchecked Sendable {
        let client: OpaquePointer
    }

    private let handle = Mutex<Handle?>(nil)

    func set(_ client: OpaquePointer) {
        let value = Handle(client: client)
        handle.withLock { $0 = value }
    }

    func clear() -> CacheClearResult {
        handle.withLock { handle -> CacheClearResult in
            guard let client = handle?.client else { return .failed }
            switch es_clear_cache(client) {
            case ES_CLEAR_CACHE_RESULT_SUCCESS: return .cleared
            case ES_CLEAR_CACHE_RESULT_ERR_THROTTLE: return .throttled
            default: return .failed
            }
        }
    }

    func delete() {
        handle.withLock { handle in
            if let client = handle?.client {
                es_delete_client(client)
            }
            handle = nil
        }
    }
}

/// Owns the Endpoint Security client: mutes the own process, subscribes to `AUTH_OPEN`, answers the fast path in
/// the handler and hands candidates to the coordinator. Fail-open: every unexpected state is answered "allow".
/// Cache clears only go through `CacheClearScheduler` (rate-limit retries off the ES thread).
final class EndpointSecurityClient: CacheClearing, Sendable {
    private let slot: ClientSlot
    private let scheduler: CacheClearScheduler

    init(coordinator: OpenCoordinator, log: Logger) throws {
        let slot = ClientSlot()
        let scheduler = CacheClearScheduler(
            log: { log.notice("\($0, privacy: .public)") }, clear: { slot.clear() }
        )
        self.slot = slot
        self.scheduler = scheduler
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) != KERN_SUCCESS {
            timebase = mach_timebase_info_data_t(numer: 0, denom: 0) // ESDeadline answers such events at once
        }
        let context = HandlerContext(
            coordinator: coordinator, cache: scheduler, timebase: (timebase.numer, timebase.denom), log: log
        )
        var created: OpaquePointer?
        let result = es_new_client(&created) { client, message in
            autoreleasepool {
                Self.handle(client: client, message: message, context: context)
            }
        }
        guard result == ES_NEW_CLIENT_RESULT_SUCCESS, let created else {
            throw EndpointSecurityClientError.newClient(result)
        }
        do {
            Self.failOpenOnDeadlineMiss(created, log: log)
            var own = try Self.ownAuditToken()
            guard es_mute_process(created, &own) == ES_RETURN_SUCCESS else { throw EndpointSecurityClientError.mute }
            var events = [ES_EVENT_TYPE_AUTH_OPEN]
            guard es_subscribe(created, &events, UInt32(events.count)) == ES_RETURN_SUCCESS else {
                throw EndpointSecurityClientError.subscribe
            }
        } catch {
            es_delete_client(created)
            throw error
        }
        slot.set(created)
    }

    deinit {
        slot.delete()
    }

    /// Only requests the clear; the scheduler performs it and retries while the kernel throttles.
    func clearCache() {
        scheduler.request()
    }

    /// `es_deadline_miss_mode_t` mirrored from the macOS 27 SDK (`ESTypes.h`): KILL = 0 (default), FAIL_CLOSED = 1,
    /// FAIL_OPEN = 2. The enum and `es_set_deadline_miss_mode` are missing from older SDKs, so the function is
    /// resolved at runtime and the constant is defined here instead of referencing the SDK symbols.
    private static let deadlineMissModeFailOpen: UInt32 = 2

    /// Where the running system has it, a missed deadline allows the open instead of killing the extension.
    private static func failOpenOnDeadlineMiss(_ client: OpaquePointer, log: Logger) {
        typealias SetDeadlineMissMode = @convention(c) (OpaquePointer, UInt32) -> es_return_t
        guard let address = RuntimeSymbol.address(of: "es_set_deadline_miss_mode") else {
            log.notice("es_set_deadline_miss_mode is not available; keeping the default KILL deadline miss mode")
            return
        }
        let setMode = unsafeBitCast(address, to: SetDeadlineMissMode.self)
        let mode = setMode(client, deadlineMissModeFailOpen)
        log.notice("es_set_deadline_miss_mode(FAIL_OPEN) returned \(mode.rawValue, privacy: .public)")
    }

    /// Human-readable reason for an `es_new_client` failure (logged before the extension exits).
    static func describe(_ result: es_new_client_result_t) -> String {
        switch result {
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED: "not permitted: Full Disk Access (TCC) is missing"
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED: "not entitled: the endpoint-security entitlement is missing"
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED: "not privileged: the extension must run as root"
        case ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS: "too many Endpoint Security clients"
        case ES_NEW_CLIENT_RESULT_ERR_INVALID_ARGUMENT: "invalid argument"
        case ES_NEW_CLIENT_RESULT_ERR_INTERNAL: "internal error"
        default: "unknown result \(result.rawValue)"
        }
    }

    // MARK: - Handler (synchronous, on the Endpoint Security thread; never awaits)

    private static func handle(
        client: OpaquePointer, message: UnsafePointer<es_message_t>, context: HandlerContext
    ) {
        let coordinator = context.coordinator
        // Fields are read through the pointer: copying the whole es_message_t on every event is wasted work.
        guard message.pointee.action_type == ES_ACTION_TYPE_AUTH else { return }
        guard message.pointee.event_type == ES_EVENT_TYPE_AUTH_OPEN else {
            es_respond_auth_result(client, message, ES_AUTH_RESULT_ALLOW, false)
            return
        }
        let token = message.pointee.event.open.file.pointee.path
        let path = UnsafeRawBufferPointer(start: token.data, count: token.data == nil ? 0 : token.length)
        let decision = coordinator.fastPathDecision(path)
        if decision.allows {
            es_respond_flags_result(client, message, UInt32.max, true)
            // A policy activated between the check and the response may cover this path: drop the cached allow.
            // Only a request: the kernel call (rate limited) runs on the scheduler task, never on this thread.
            if coordinator.policyGeneration != decision.generation {
                context.cache.request()
            }
            return
        }
        // Read the clock before any string is built so the decoding time counts against the deadline.
        let remaining = ESDeadline.remaining(
            deadline: message.pointee.deadline, now: mach_absolute_time(), timebase: context.timebase
        )
        let process = message.pointee.process.pointee
        let responsible = message.pointee.version >= 4 ? processToken(process.responsible_audit_token) : nil
        let request = OpenRequest(
            file: OpenCoordinator.decodePath(path),
            process: ProcessIdentity(
                path: string(process.executable.pointee.path), signingId: string(process.signing_id),
                teamId: string(process.team_id)
            ),
            responsible: responsible,
            remaining: remaining,
            // Usually the opener is its own responsible process: use its kernel-sourced identity, no lookup.
            responsibleIsProcess: responsible != nil && responsible == processToken(process.audit_token)
        )
        es_retain_message(message)
        let retained = RetainedMessage(client: client, message: message, log: context.log)
        coordinator.handleCandidate(request) { retained.respond($0) }
    }

    /// Lossy UTF-8; an absent token is the empty string ("absent" in `ProcessIdentity`).
    private static func string(_ token: es_string_token_t) -> String {
        guard token.data != nil else { return "" }
        return OpenCoordinator.decodePath(UnsafeRawBufferPointer(start: token.data, count: token.length))
    }

    private static func processToken(_ token: audit_token_t) -> ProcessToken? {
        let words = [
            token.val.0, token.val.1, token.val.2, token.val.3, token.val.4, token.val.5, token.val.6, token.val.7,
        ]
        guard words.contains(where: { $0 != 0 }) else { return nil }
        return ProcessToken(auditTokenWords: words)
    }

    private static func ownAuditToken() throws -> audit_token_t {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), words, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw EndpointSecurityClientError.auditToken(result) }
        return token
    }
}
