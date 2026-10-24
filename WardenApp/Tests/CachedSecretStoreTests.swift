import Foundation
import Synchronization
import XCTest

final class CachedSecretStoreTests: XCTestCase {
    private struct Rig {
        let base: ScriptedSecretStore
        let clock = ManualClock()
        let store: CachedSecretStore<ManualClock>

        init(token: String? = "t1") {
            base = ScriptedSecretStore(token: token)
            store = CachedSecretStore(base: base, clock: clock, retryAfterFailure: .seconds(60))
        }
    }

    private static let denied = KeychainError.reenterToken(errSecAuthFailed)

    func testReadsTheBaseStoreOnce() async throws {
        let rig = Rig()
        for _ in 0 ..< 3 {
            let token = try await rig.store.token()
            XCTAssertEqual(token, "t1")
        }
        XCTAssertEqual(rig.base.reads.count, 1)
    }

    func testCachesAMissingToken() async throws {
        let rig = Rig(token: nil)
        _ = try await rig.store.token()
        let token = try await rig.store.token()
        XCTAssertNil(token)
        XCTAssertEqual(rig.base.reads.count, 1)
    }

    func testSaveAndDeleteUpdateTheCacheWithoutReading() async throws {
        let rig = Rig()
        try await rig.store.saveToken("t2")
        let saved = try await rig.store.token()
        XCTAssertEqual(saved, "t2")
        try await rig.store.deleteToken()
        let deleted = try await rig.store.token()
        XCTAssertNil(deleted)
        XCTAssertEqual(rig.base.reads.count, 0)
        XCTAssertEqual(rig.base.saved, ["t2"])
        XCTAssertEqual(rig.base.deletes, 1)
    }

    func testFailedReadIsRetriedAtMostOncePerInterval() async throws {
        let rig = Rig()
        rig.base.setReadFailure(Self.denied)
        for _ in 0 ..< 3 {
            do {
                _ = try await rig.store.token()
                XCTFail("expected the read failure")
            } catch {
                XCTAssertEqual(error as? KeychainError, Self.denied, "the last failure is reported meanwhile")
            }
        }
        XCTAssertEqual(rig.base.reads.count, 1, "no new prompt within the interval")

        rig.base.setReadFailure(nil) // e.g. the user allowed access later
        rig.clock.advance(by: .seconds(59))
        _ = try? await rig.store.token()
        XCTAssertEqual(rig.base.reads.count, 1)
        rig.clock.advance(by: .seconds(1))
        let token = try await rig.store.token()
        XCTAssertEqual(token, "t1", "a failure is not cached for good")
        _ = try await rig.store.token()
        XCTAssertEqual(rig.base.reads.count, 2)
    }

    func testSavingAfterAFailedReadRecoversAtOnce() async throws {
        let rig = Rig()
        rig.base.setReadFailure(Self.denied)
        _ = try? await rig.store.token()
        try await rig.store.saveToken("t2")
        let token = try await rig.store.token()
        XCTAssertEqual(token, "t2")
        XCTAssertEqual(rig.base.reads.count, 1)
    }

    func testFailedSaveForgetsTheCachedToken() async throws {
        let rig = Rig()
        _ = try await rig.store.token()
        rig.base.setWriteFailure(KeychainError.failure(errSecIO))
        do {
            try await rig.store.saveToken("t2")
            XCTFail("expected the save failure")
        } catch {
            XCTAssertEqual(error as? KeychainError, .failure(errSecIO))
        }
        do {
            try await rig.store.deleteToken()
            XCTFail("expected the delete failure")
        } catch {
            XCTAssertEqual(error as? KeychainError, .failure(errSecIO))
        }
        _ = try await rig.store.token()
        XCTAssertEqual(rig.base.reads.count, 2, "the stored value is unknown after a failed write")
    }

    func testConcurrentReadsShareOneBaseRead() async throws {
        let rig = Rig()
        rig.base.setHoldsReads(true)
        let store = rig.store
        let first = Task { try await store.token() }
        let second = Task { try await store.token() }
        await rig.base.reads.wait(for: 1)
        rig.base.releaseReads()
        let tokens = try await [first.value, second.value]
        XCTAssertEqual(tokens, ["t1", "t1"])
        XCTAssertEqual(rig.base.reads.count, 1)
    }

    func testSaveDuringAReadWinsOverTheOlderReadResult() async throws {
        let rig = Rig()
        rig.base.setHoldsReads(true)
        let store = rig.store
        let read = Task { try await store.token() }
        await rig.base.reads.wait(for: 1)
        try await store.saveToken("t2")
        rig.base.releaseReads() // the read returns the older "t1"
        _ = try await read.value
        let token = try await store.token()
        XCTAssertEqual(token, "t2")
    }
}

/// Counts and scripts `SecretStoring` calls; a held read suspends until `releaseReads()`.
final class ScriptedSecretStore: SecretStoring {
    private struct State {
        var token: String?
        var readFailure: KeychainError?
        var writeFailure: KeychainError?
        var holdsReads = false
        var held: [CheckedContinuation<Void, Never>] = []
        var saved: [String] = []
        var deletes = 0
    }

    private let state: Mutex<State>
    let reads = CallLatch()

    init(token: String?) {
        state = Mutex(State(token: token))
    }

    func setReadFailure(_ error: KeychainError?) {
        state.withLock { $0.readFailure = error }
    }

    func setWriteFailure(_ error: KeychainError?) {
        state.withLock { $0.writeFailure = error }
    }

    func setHoldsReads(_ holds: Bool) {
        state.withLock { $0.holdsReads = holds }
    }

    func releaseReads() {
        let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer {
                state.held = []
                state.holdsReads = false
            }
            return state.held
        }
        held.forEach { $0.resume() }
    }

    var saved: [String] {
        state.withLock { $0.saved }
    }

    var deletes: Int {
        state.withLock { $0.deletes }
    }

    func token() async throws -> String? {
        let (holds, snapshot) = state.withLock { ($0.holdsReads, $0.token) }
        if holds {
            await withCheckedContinuation { continuation in
                state.withLock { $0.held.append(continuation) }
                reads.increment()
            }
        } else {
            reads.increment()
        }
        if let failure = state.withLock({ $0.readFailure }) {
            throw failure
        }
        return snapshot
    }

    func saveToken(_ token: String) async throws {
        try state.withLock { state in
            if let failure = state.writeFailure {
                throw failure
            }
            state.token = token
            state.saved.append(token)
        }
    }

    func deleteToken() async throws {
        try state.withLock { state in
            if let failure = state.writeFailure {
                throw failure
            }
            state.token = nil
            state.deletes += 1
        }
    }
}
