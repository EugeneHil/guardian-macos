import Foundation
import Synchronization
import XCTest

private final class FakeCache: CacheClearing {
    let count = Mutex(0)
    func clearCache() {
        count.withLock { $0 += 1 }
    }
}

private final class LogBox: Sendable {
    let lines = Mutex<[String]>([])
    func add(_ line: String) {
        lines.withLock { $0.append(line) }
    }
}

final class PolicyControllerTests: XCTestCase {
    private var dir = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        dir = try PolicyFixtures.makeTempDir()
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private var fileURL: URL {
        dir.appendingPathComponent("policy.json")
    }

    private struct Rig {
        let controller: PolicyController
        let holder: PolicyHolder
        let cache: FakeCache
        let log: LogBox
    }

    private func make() -> Rig {
        let holder = PolicyHolder()
        let cache = FakeCache()
        let log = LogBox()
        let controller = PolicyController(
            holder: holder, store: PolicyStore(fileURL: fileURL), cache: cache, log: { log.add($0) }
        )
        return Rig(controller: controller, holder: holder, cache: cache, log: log)
    }

    func testStartLoadsCachedPolicy() async throws {
        try PolicyFixtures.policy(version: 4).write(to: fileURL)
        let rig = make()
        await rig.controller.start()
        XCTAssertEqual(rig.holder.version, 4)
        let version = await rig.controller.currentVersion()
        XCTAssertEqual(version, 4)
        XCTAssertEqual(rig.cache.count.withLock { $0 }, 0)
    }

    func testStartWithoutCacheStaysEmpty() async {
        let rig = make()
        await rig.controller.start()
        XCTAssertNil(rig.holder.engine())
        let version = await rig.controller.currentVersion()
        XCTAssertEqual(version, 0)
    }

    func testCorruptCacheAllowsAndKeepsRunning() async throws {
        try Data([0xFF, 0x00, 0x7B]).write(to: fileURL)
        let rig = make()
        await rig.controller.start()
        XCTAssertNil(rig.holder.engine())
        XCTAssertFalse(rig.log.lines.withLock { $0 }.isEmpty)
    }

    func testApplyPersistsAndClearsCache() async throws {
        let rig = make()
        let data = PolicyFixtures.policy(version: 9)
        let version = try await rig.controller.apply(data)
        XCTAssertEqual(version, 9)
        XCTAssertEqual(rig.holder.version, 9)
        XCTAssertEqual(rig.cache.count.withLock { $0 }, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
    }

    func testInvalidPushedPolicyKeepsPrevious() async throws {
        let rig = make()
        _ = try await rig.controller.apply(PolicyFixtures.policy(version: 2))
        do {
            _ = try await rig.controller.apply(Data("{\"schemaVersion\":1}".utf8))
            XCTFail("expected throw")
        } catch let PolicyApplyError.invalid(errors) {
            XCTAssertFalse(errors.isEmpty)
        }
        let version = await rig.controller.currentVersion()
        XCTAssertEqual(version, 2)
        XCTAssertEqual(rig.holder.version, 2)
        XCTAssertEqual(rig.cache.count.withLock { $0 }, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL), PolicyFixtures.policy(version: 2))
    }

    func testApplyStillActivatesWhenSaveFails() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let rig = make()
        let version = try await rig.controller.apply(PolicyFixtures.policy(version: 5))
        XCTAssertEqual(version, 5)
        XCTAssertEqual(rig.holder.version, 5)
        XCTAssertEqual(rig.cache.count.withLock { $0 }, 1)
        XCTAssertFalse(rig.log.lines.withLock { $0 }.isEmpty)
    }
}
