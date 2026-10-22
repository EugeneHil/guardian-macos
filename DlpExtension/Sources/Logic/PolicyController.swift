import CoreBridge
import Foundation

/// Implemented by the Endpoint Security adapter: drops the kernel's cached verdicts after a policy change.
protocol CacheClearing: Sendable {
    func clearCache()
}

enum PolicyApplyError: Error, Equatable {
    case invalid([String])
}

/// Owns policy state transitions. Fail-open: nothing here may leave the holder in a state that denies by accident.
actor PolicyController {
    private let holder: PolicyHolder
    private let store: PolicyStore
    private let cache: any CacheClearing
    private let log: @Sendable (String) -> Void

    init(
        holder: PolicyHolder, store: PolicyStore, cache: any CacheClearing,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.holder = holder
        self.store = store
        self.cache = cache
        self.log = log
    }

    /// Activates the cached policy if there is a valid one; every failure leaves the holder empty (allow).
    func start() async {
        do {
            guard let data = try await store.load() else {
                log("no cached policy; allowing until one is applied")
                return
            }
            let policy = try WDPolicy(json: data)
            holder.set(WDEngine(policy: policy), version: policy.version)
            log("loaded cached policy version \(policy.version)")
        } catch {
            log("cached policy unusable, allowing everything: \(error.localizedDescription)")
        }
    }

    /// Validates, persists, activates and clears the ES cache. An invalid policy keeps the previous engine.
    func apply(_ data: Data) async throws -> Int64 {
        let policy: WDPolicy
        do {
            policy = try WDPolicy(json: data)
        } catch {
            let nsError = error as NSError
            let details = nsError.userInfo[WDPolicyValidationErrorsKey] as? [String]
            let messages = details ?? [nsError.localizedDescription]
            log("rejected pushed policy: \(messages.joined(separator: "; "))")
            throw PolicyApplyError.invalid(messages)
        }
        do {
            try await store.save(data)
        } catch {
            log("could not persist policy, activating in memory only: \(error.localizedDescription)")
        }
        holder.set(WDEngine(policy: policy), version: policy.version)
        cache.clearCache()
        return policy.version
    }

    func currentVersion() -> Int64 {
        holder.version
    }
}
