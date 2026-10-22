import Foundation
import XCTest

final class PolicyStoreTests: XCTestCase {
    private var dir = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        dir = try PolicyFixtures.makeTempDir()
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func testLoadMissingReturnsNil() async throws {
        let store = PolicyStore(fileURL: dir.appendingPathComponent("sub/policy.json"))
        let loaded = try await store.load()
        XCTAssertNil(loaded)
    }

    func testSaveThenLoadRoundTrips() async throws {
        let store = PolicyStore(fileURL: dir.appendingPathComponent("sub/policy.json"))
        let data = Data("hello".utf8)
        try await store.save(data)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, data)
        try await store.save(Data("second".utf8))
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, Data("second".utf8))
    }

    func testSavedFileIsMode0600() async throws {
        let url = dir.appendingPathComponent("policy.json")
        let store = PolicyStore(fileURL: url)
        try await store.save(Data("x".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    func testSaveIsAtomicNoPartialFileOnFailure() async throws {
        let url = dir.appendingPathComponent("policy.json")
        let store = PolicyStore(fileURL: url)
        try await store.save(Data("old".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        do {
            try await store.save(Data("new".utf8))
            XCTFail("expected save to throw")
        } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["policy.json"])
    }

    func testUnreadableFileThrows() async throws {
        let url = dir.appendingPathComponent("policy.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = PolicyStore(fileURL: url)
        do {
            _ = try await store.load()
            XCTFail("expected load to throw")
        } catch is PolicyStoreError {}
    }

    // MARK: - Directory

    private func mode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    func testSaveCreatesDirectoryWithMode0700() async throws {
        let sub = dir.appendingPathComponent("Warden")
        let store = PolicyStore(fileURL: sub.appendingPathComponent("policy.json"))
        try await store.save(Data("x".utf8))
        XCTAssertEqual(try mode(sub), 0o700)
    }

    func testPrepareCreatesDirectoryWithMode0700() async throws {
        let sub = dir.appendingPathComponent("Warden")
        let store = PolicyStore(fileURL: sub.appendingPathComponent("policy.json"))
        try await store.prepareDirectory()
        XCTAssertEqual(try mode(sub), 0o700)
    }

    func testPrepareTightensExistingDirectory() async throws {
        let sub = dir.appendingPathComponent("Warden")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path)
        let store = PolicyStore(fileURL: sub.appendingPathComponent("policy.json"))
        try await store.prepareDirectory()
        XCTAssertEqual(try mode(sub), 0o700)
    }

    func testPrepareRemovesLeftoverTempFilesOnly() async throws {
        let url = dir.appendingPathComponent("policy.json")
        let store = PolicyStore(fileURL: url)
        try await store.save(Data("keep".utf8))
        let leftover = dir.appendingPathComponent(".policy.json.\(UUID().uuidString).tmp")
        try Data("partial".utf8).write(to: leftover)
        let unrelated = dir.appendingPathComponent("notes.tmp")
        try Data("other".utf8).write(to: unrelated)
        try await store.prepareDirectory()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["notes.tmp", "policy.json"])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, Data("keep".utf8))
    }

    func testPrepareFailsWhenParentIsAFile() async throws {
        let blocker = dir.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        let store = PolicyStore(fileURL: blocker.appendingPathComponent("Warden/policy.json"))
        do {
            try await store.prepareDirectory()
            XCTFail("expected prepareDirectory to throw")
        } catch {}
    }
}
