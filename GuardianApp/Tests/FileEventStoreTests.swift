import Foundation
import XCTest

final class FileEventStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("guardian-store-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var directory: URL {
        root.appendingPathComponent("app")
    }

    private func makeStore() -> FileEventStore {
        FileEventStore(directory: directory)
    }

    private func sample(_ count: Int) -> [AccessEvent] {
        (0 ..< count).map { index in
            AccessEvent(
                id: UUID(), timestamp: Date(timeIntervalSince1970: Double(index) + 0.25),
                process: ProcessIdentity(path: "/bin/tool", signingId: "id", teamId: "T"),
                responsible: nil, file: "/data/file\(index)", decision: .deny, ruleId: "r\(index)"
            )
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? Int) ?? -1
    }

    func testMissingFileLoadsEmpty() throws {
        XCTAssertEqual(try makeStore().load(), [])
    }

    func testRoundTrip() throws {
        let store = makeStore()
        let events = sample(3)
        try store.save(events)
        XCTAssertEqual(try makeStore().load(), events)
    }

    func testPermissions() throws {
        let store = makeStore()
        try store.save(sample(1))
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(store.fileURL), 0o600)
    }

    func testCorruptFileLoadsEmpty() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(try store.load(), [])
    }

    func testEmptySaveRemovesTheFile() throws {
        let store = makeStore()
        try store.save(sample(2))
        try store.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try store.load(), [])
        try store.save([])
    }

    func testOverwriteReplacesContentAndKeepsPermissions() throws {
        let store = makeStore()
        try store.save(sample(5))
        let second = sample(2)
        try store.save(second)
        XCTAssertEqual(try store.load(), second)
        XCTAssertEqual(try permissions(store.fileURL), 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [store.fileURL.lastPathComponent], "no temporary files are left behind")
    }
}
