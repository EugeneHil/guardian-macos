import Darwin
import Foundation
import Security
import Synchronization

/// Resolves the code-signing identity of a live process (the responsible process of an `AUTH_OPEN`).
///
/// Every step is a short synchronous libproc/Security call without signature validation, and any failure returns
/// `nil` at once. Results (failures included) are cached per process instance. Lookups that miss the cache run one
/// at a time on `Inspector`, so the blocking calls can hold at most one cooperative-pool thread and the
/// coordinator's watchdogs always find a free one; other callers suspend instead of blocking.
final class SecurityProcessResolver: ProcessResolving {
    private static let cacheLimit = 1024

    private actor Inspector {
        func lookUp(_ token: ProcessToken, in resolver: SecurityProcessResolver) -> ProcessIdentity? {
            // A caller queued behind the same token finds the result of the lookup that ran first.
            if let hit = resolver.cached(token) {
                return hit
            }
            let identity = SecurityProcessResolver.lookUp(token)
            resolver.store(identity, for: token)
            return identity
        }
    }

    private let cache = Mutex<[ProcessToken: ProcessIdentity?]>([:])
    private let inspector = Inspector()

    func identity(of token: ProcessToken) async -> ProcessIdentity? {
        if let hit = cached(token) {
            return hit
        }
        return await inspector.lookUp(token, in: self)
    }

    /// `.some(nil)` is a cached failure; `nil` means not cached.
    private func cached(_ token: ProcessToken) -> ProcessIdentity?? {
        cache.withLock { $0[token] }
    }

    private func store(_ identity: ProcessIdentity?, for token: ProcessToken) {
        cache.withLock { cache in
            if cache.count >= Self.cacheLimit {
                cache.removeAll(keepingCapacity: true)
            }
            cache[token] = .some(identity)
        }
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
