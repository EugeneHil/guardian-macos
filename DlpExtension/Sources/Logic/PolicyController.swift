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
    private let store: any PolicyPersisting
    private let cache: any CacheClearing
    private let log: @Sendable (String) -> Void
    /// Bumped by every `apply`; lets a suspended `start()` notice that a newer policy was pushed meanwhile.
    private var generation = 0
    /// Tail of the persistence chain: saves run strictly in the order the applies started.
    private var lastSave: Task<Void, Never>?

    init(
        holder: PolicyHolder, store: any PolicyPersisting, cache: any CacheClearing,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.holder = holder
        self.store = store
        self.cache = cache
        self.log = log
    }

    /// Activates the cached policy if there is a valid one; every failure leaves the holder empty (allow).
    /// A policy applied while the cache was loading wins over the cached one.
    func start() async {
        let startedAt = generation
        do {
            guard let data = try await store.load() else {
                log("no cached policy; allowing until one is applied")
                return
            }
            let policy = try WDPolicy(json: data)
            guard generation == startedAt else {
                log("ignoring cached policy: a newer policy was applied while loading")
                return
            }
            holder.set(policy: policy)
            // Fast-path allows answered while the cache was loading may cover paths this policy protects.
            cache.clearCache()
            log("loaded cached policy version \(policy.version)")
        } catch {
            log("cached policy unusable, allowing everything: \(error.localizedDescription)")
        }
    }

    /// Validates, activates (memory first, synchronously, so the last-started apply always wins), clears the ES
    /// cache and persists. An invalid policy keeps the previous engine; a failing save is logged only.
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
        generation += 1
        holder.set(policy: policy)
        cache.clearCache()

        let previous = lastSave
        let store = store
        let log = log
        let save = Task {
            await previous?.value
            do {
                try await store.save(data)
            } catch {
                log("could not persist policy, activated in memory only: \(error.localizedDescription)")
            }
        }
        lastSave = save
        await save.value
        return policy.version
    }

    func currentVersion() -> Int64 {
        holder.version
    }
}
