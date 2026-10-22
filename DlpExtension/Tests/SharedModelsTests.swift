import Foundation
import XCTest

final class SharedModelsTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_792_571_400) // 2026-10-21T08:30:00Z

    private func makeEvent(
        responsible: ProcessIdentity? = nil,
        file: String = "/Users/alice/Documents/report.pdf",
        ruleId: String? = "block-docs"
    ) -> AccessEvent {
        AccessEvent(
            id: UUID(),
            timestamp: fixedDate,
            process: ProcessIdentity(path: "/usr/bin/curl", signingId: "com.apple.curl", teamId: ""),
            responsible: responsible,
            file: file,
            decision: .deny,
            ruleId: ruleId
        )
    }

    private func payloadItem(_ event: AccessEvent) throws -> [String: Any] {
        let data = try AccessEvent.uploadPayload([event])
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(array.count, 1)
        return try XCTUnwrap(array.first)
    }

    func testEventRoundTripsThroughXPCCoding() throws {
        let term = ProcessIdentity(path: "/Applications/Term.app", signingId: "t", teamId: "ABC")
        let event = makeEvent(responsible: term)
        XCTAssertEqual(try XPCCoding.decode(XPCCoding.encode(event)), event)
        let list = [event, makeEvent(ruleId: nil)]
        let listData = try JSONEncoder.xpc.encode(list)
        XCTAssertEqual(try XPCCoding.decodeList(listData), list)
    }

    func testUploadPayloadMatchesServerContract() throws {
        let item = try payloadItem(makeEvent())
        XCTAssertEqual(item["ts"] as? String, "2026-10-21T08:30:00Z")
        let process = try XCTUnwrap(item["process"] as? [String: Any])
        XCTAssertEqual(process["path"] as? String, "/usr/bin/curl")
        XCTAssertEqual(process["signingId"] as? String, "com.apple.curl")
        XCTAssertNil(process["teamId"])
        XCTAssertEqual(item["responsible"] as? NSNull, NSNull())
        XCTAssertEqual(item["file"] as? String, "/Users/alice/Documents/report.pdf")
        XCTAssertEqual(item["decision"] as? String, "deny")
        XCTAssertEqual(item["ruleId"] as? String, "block-docs")
        XCTAssertNil(item["id"])
        XCTAssertNil(item["timestamp"])
    }

    func testUploadPayloadOmitsEmptyRuleIdAndKeepsResponsible() throws {
        let responsible = ProcessIdentity(path: "/Applications/Term.app", signingId: "", teamId: "ABC")
        let item = try payloadItem(makeEvent(responsible: responsible, ruleId: ""))
        XCTAssertNil(item["ruleId"])
        let resp = try XCTUnwrap(item["responsible"] as? [String: Any])
        XCTAssertEqual(resp["teamId"] as? String, "ABC")
        XCTAssertNil(resp["signingId"])
    }

    func testUploadPayloadTruncatesLongStringsOnCharacterBoundary() throws {
        let long = String(repeating: "\u{1F600}", count: 1250) // 5000 bytes
        XCTAssertEqual(long.utf8.count, 5000)
        let item = try payloadItem(makeEvent(file: long))
        let file = try XCTUnwrap(item["file"] as? String)
        XCTAssertLessThanOrEqual(file.utf8.count, 4096)
        XCTAssertEqual(file.utf8.count, 4096)
        XCTAssertNotNil(String(data: Data(file.utf8), encoding: .utf8))
        XCTAssertTrue(file.allSatisfy { $0 == "\u{1F600}" })
    }
}
