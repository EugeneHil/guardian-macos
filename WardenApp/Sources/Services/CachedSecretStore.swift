import Foundation

/// Keeps the agent token in memory so the Keychain is read once, not on every API call. After a rebuild the legacy
/// keychain ACL can answer a read with a blocking access dialog (see `KeychainSecretStore`); without the cache that
/// dialog would come back on every sync tick.
///
/// - A successful read (also "no token") is cached until `saveToken` or `deleteToken` replaces it.
/// - A failed read is not cached for good: it is reported again without touching the Keychain for
///   `retryAfterFailure`, then the next call reads again, so a denied prompt can reappear at most once per interval.
/// - Concurrent reads share one Keychain read; a write that lands during a read wins over that read's result.
/// - A failed write forgets the cached value (the stored state is unknown), so the next call reads again.
actor CachedSecretStore<C: Clock>: SecretStoring where C.Duration == Duration {
    private enum Cache {
        case unknown
        case loaded(String?)
        case failed(any Error, retryAt: C.Instant)
    }

    private let base: any SecretStoring
    private let clock: C
    private let retryAfterFailure: Duration
    private var cache = Cache.unknown
    private var read: (generation: Int, task: Task<String?, any Error>)?
    /// Bumped by every write, so a read that started earlier cannot overwrite what the write cached.
    private var generation = 0

    init(base: any SecretStoring, clock: C, retryAfterFailure: Duration = .seconds(60)) {
        self.base = base
        self.clock = clock
        self.retryAfterFailure = retryAfterFailure
    }

    func token() async throws -> String? {
        switch cache {
        case let .loaded(token):
            return token
        case let .failed(error, retryAt) where clock.now < retryAt:
            throw error
        case .failed, .unknown:
            return try await readThrough()
        }
    }

    func saveToken(_ token: String) async throws {
        let write = beginWrite()
        do {
            try await base.saveToken(token)
            settleWrite(write, .loaded(token))
        } catch {
            settleWrite(write, .unknown)
            throw error
        }
    }

    func deleteToken() async throws {
        let write = beginWrite()
        do {
            try await base.deleteToken()
            settleWrite(write, .loaded(nil))
        } catch {
            settleWrite(write, .unknown)
            throw error
        }
    }

    private func readThrough() async throws -> String? {
        let current: Task<String?, any Error>
        if let read, read.generation == generation {
            current = read.task
        } else {
            let base = base
            current = Task { try await base.token() }
            read = (generation, current)
        }
        let started = generation
        let result = await current.result
        if started == generation, read?.task == current {
            read = nil
            switch result {
            case let .success(token):
                cache = .loaded(token)
            case let .failure(error):
                cache = .failed(error, retryAt: clock.now.advanced(by: retryAfterFailure))
            }
        }
        return try result.get()
    }

    private func beginWrite() -> Int {
        generation += 1
        read = nil
        return generation
    }

    /// Caches the outcome of the latest write. When writes overlap, the final Keychain value is not known here, so a
    /// superseded write forgets the cache instead and the next call reads again.
    private func settleWrite(_ write: Int, _ outcome: Cache) {
        cache = write == generation ? outcome : .unknown
    }
}
