import EndpointSecurity
import Foundation
import os

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

/// Owns the Endpoint Security client: mutes the own process, subscribes to `AUTH_OPEN`, answers the fast path in
/// the handler and hands candidates to the coordinator. Fail-open: every unexpected state is answered "allow".
final class EndpointSecurityClient: CacheClearing, @unchecked Sendable {
    // @unchecked: `client` is an immutable C handle; ES client calls are documented as thread-safe.
    private let client: OpaquePointer
    private let log: Logger

    init(coordinator: OpenCoordinator, log: Logger) throws {
        self.log = log
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) != KERN_SUCCESS {
            timebase = mach_timebase_info_data_t(numer: 0, denom: 0) // ESDeadline answers such events at once
        }
        let scale = (numer: timebase.numer, denom: timebase.denom)
        var created: OpaquePointer?
        let result = es_new_client(&created) { client, message in
            autoreleasepool {
                Self.handle(client: client, message: message, coordinator: coordinator, timebase: scale, log: log)
            }
        }
        guard result == ES_NEW_CLIENT_RESULT_SUCCESS, let created else {
            throw EndpointSecurityClientError.newClient(result)
        }
        do {
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
        // Assigned last: a throw above leaves `self` uninitialized, so `deinit` cannot delete the client twice.
        client = created
    }

    deinit {
        es_delete_client(client)
    }

    func clearCache() {
        let result = es_clear_cache(client)
        if result != ES_CLEAR_CACHE_RESULT_SUCCESS {
            log.error("es_clear_cache failed: \(result.rawValue, privacy: .public)")
        }
    }

    // MARK: - Handler (synchronous, on the Endpoint Security thread; never awaits)

    private static func handle(
        client: OpaquePointer, message: UnsafePointer<es_message_t>, coordinator: OpenCoordinator,
        timebase: (numer: UInt32, denom: UInt32), log: Logger
    ) {
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
            if coordinator.policyGeneration != decision.generation {
                es_clear_cache(client)
            }
            return
        }
        // Read the clock before any string is built so the decoding time counts against the deadline.
        let remaining = ESDeadline.remaining(
            deadline: message.pointee.deadline, now: mach_absolute_time(), timebase: timebase
        )
        let process = message.pointee.process.pointee
        let request = OpenRequest(
            file: OpenCoordinator.decodePath(path),
            process: ProcessIdentity(
                path: string(process.executable.pointee.path), signingId: string(process.signing_id),
                teamId: string(process.team_id)
            ),
            responsible: message.pointee.version >= 4 ? processToken(process.responsible_audit_token) : nil,
            remaining: remaining
        )
        es_retain_message(message)
        let retained = RetainedMessage(client: client, message: message, log: log)
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
