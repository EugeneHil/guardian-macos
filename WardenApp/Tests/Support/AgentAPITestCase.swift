import Foundation
import XCTest

/// Shared fixtures for the `HTTPAgentAPI` tests (a fake transport, valid settings and token).
class AgentAPITestCase: XCTestCase {
    static let token = "wdn_" + String(repeating: "ab", count: 32)
    static let pin = Data(repeating: 7, count: 32).base64EncodedString()
    static let jsonType = ["Content-Type": "application/json; charset=utf-8"]

    func makeAPI(
        url: String? = "https://warden.test:8443",
        pin: String = AgentAPITestCase.pin,
        secrets: any SecretStoring = InMemorySecretStore(token: AgentAPITestCase.token),
        transport: FakeHTTPTransport
    ) -> HTTPAgentAPI {
        let settings = AgentSettings(serverURL: url.flatMap { URL(string: $0) }, spkiPin: pin)
        return HTTPAgentAPI(settings: { settings }, secrets: secrets, transport: transport)
    }

    func policyBody(version: Int = 3) -> Data {
        Data(#"{"rules":[],"schemaVersion":1,"version":\#(version)}"#.utf8)
    }

    func policyHeaders(
        etag: String = "\"v3\"", type: String = "application/json; charset=utf-8"
    ) -> [String: String] {
        ["ETag": etag, "Content-Type": type]
    }

    func fetchError(
        _ api: HTTPAgentAPI, etag: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async -> (any Error)? {
        do {
            let result = try await api.fetchPolicy(etag: etag)
            XCTFail("expected an error, got \(result)", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    func postError(
        _ api: HTTPAgentAPI, _ events: [AccessEvent]? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async -> (any Error)? {
        do {
            try await api.postEvents(events ?? [Self.event()])
            XCTFail("expected an error", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    func assertFetch(
        _ expected: AgentAPIError, status: Int = 200, headers: [String: String] = [:], body: Data = Data(),
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let api = makeAPI(transport: FakeHTTPTransport(status: status, headers: headers, body: body))
        let error = await fetchError(api, file: file, line: line)
        XCTAssertEqual(error as? AgentAPIError, expected, file: file, line: line)
    }

    func assertPost(
        _ expected: AgentAPIError, status: Int, headers: [String: String] = [:],
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let api = makeAPI(transport: FakeHTTPTransport(status: status, headers: headers, body: Data()))
        let error = await postError(api, file: file, line: line)
        XCTAssertEqual(error as? AgentAPIError, expected, file: file, line: line)
    }

    static func event(file: String = "/Users/alice/report.pdf") -> AccessEvent {
        AccessEvent(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_792_571_400),
            process: ProcessIdentity(path: "/usr/bin/curl", signingId: "com.apple.curl", teamId: ""),
            responsible: nil,
            file: file,
            decision: .deny,
            ruleId: "block-docs"
        )
    }
}
