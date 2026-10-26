import Darwin
import Foundation
import os
import Security

/// Resolves the code-signing identity of a live process (the responsible process of an `AUTH_OPEN`).
///
/// Every step is a short synchronous libproc/Security call without signature validation, and any failure returns
/// `nil` at once. Results are cached per process instance (failures only briefly, see `ProcessIdentityCache`).
/// Lookups that miss the cache run one at a time on `Inspector`, so the blocking calls can hold at most one
/// cooperative-pool thread and the coordinator's watchdogs always find a free one; other callers suspend instead
/// of blocking.
final class SecurityProcessResolver: ProcessResolving {
    private actor Inspector {
        func lookUp(_ token: ProcessToken, in resolver: SecurityProcessResolver) -> ProcessIdentity? {
            // A caller queued behind the same token finds the result of the lookup that ran first.
            if let hit = resolver.cache.lookup(token) {
                return hit
            }
            let identity = SecurityProcessResolver.lookUp(token)
            resolver.cache.store(identity, for: token)
            return identity
        }
    }

    private let cache = ProcessIdentityCache()
    private let inspector = Inspector()
    private let diagnostics: DiagnosticsRecorder
    /// `.debug` detail per lookup (numbers and fixed words only), for the per-binary-kind latency check.
    private let diagLog: Logger

    init(diagnostics: DiagnosticsRecorder, diagLog: Logger) {
        self.diagnostics = diagnostics
        self.diagLog = diagLog
    }

    func identity(of token: ProcessToken) async -> ProcessIdentity? {
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let hit = cache.lookup(token)
        let identity: ProcessIdentity? = if let hit {
            hit
        } else {
            await inspector.lookUp(token, in: self)
        }
        let nanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- started
        let metric: DiagnosticMetric = hit != nil ? .lookupCached : (identity != nil ? .lookupResolved : .lookupFailed)
        diagnostics.record(metric, nanoseconds: nanoseconds)
        if hit == nil, let identity {
            diagnostics.increment(identity.teamId.isEmpty ? .resolvedTeamIdEmpty : .resolvedTeamIdPresent)
        }
        diagLog.debug("""
        lookup outcome=\(metric.label, privacy: .public) durationUs=\(nanoseconds / 1000, privacy: .public) \
        teamIdEmpty=\(identity?.teamId.isEmpty ?? true, privacy: .public)
        """)
        return identity
    }

    /// Code object first (bound to the exact process instance when the audit token is known), then the path by pid,
    /// then the signing information with dynamic status, which asks the kernel about that same instance again: a pid
    /// reused in between makes the last step fail instead of mixing two processes.
    private static func lookUp(_ token: ProcessToken) -> ProcessIdentity? {
        guard let code = guestCode(token), let path = executablePath(token.pid) else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation)
        // SecCodeRef is a SecStaticCodeRef for this call (documented in SecCode.h).
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let values = info as? [String: Any]
        else { return nil }
        return ProcessIdentity(
            path: path,
            signingId: values[kSecCodeInfoIdentifier as String] as? String ?? "",
            teamId: values[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        )
    }

    private static func guestCode(_ token: ProcessToken) -> SecCode? {
        let attributes: [String: Any]
        if let words = token.auditToken, words.count == 8 {
            let bytes = words.withUnsafeBytes { Data($0) }
            attributes = [kSecGuestAttributeAudit as String: bytes]
        } else {
            attributes = [kSecGuestAttributePid as String: NSNumber(value: token.pid)]
        }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &code) == errSecSuccess
        else { return nil }
        return code
    }

    private static func executablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro is not imported into Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return buffer.withUnsafeBytes { bytes in
            OpenCoordinator.decodePath(UnsafeRawBufferPointer(rebasing: bytes[..<Int(length)]))
        }
    }
}
