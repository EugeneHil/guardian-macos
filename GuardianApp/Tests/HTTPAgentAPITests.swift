import Foundation
import Synchronization
import XCTest

final class HTTPAgentAPITests: AgentAPITestCase {
    // MARK: - GET /api/v1/policy request

    func testFetchSendsBearerAndIfNoneMatch() async throws {
        let transport = FakeHTTPTransport(status: 304)
        _ = try await makeAPI(transport: transport).fetchPolicy(etag: "\"v3\"")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://guardian.test:8443/api/v1/policy")
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "Authorization": "Bearer \(Self.token)",
            "If-None-Match": "\"v3\"",
        ])
        XCTAssertNil(request.httpBody)
    }

    func testFetchWithoutEtagSendsOnlyAuthorization() async throws {
        let transport = FakeHTTPTransport(status: 304)
        _ = try await makeAPI(transport: transport).fetchPolicy(etag: nil)
        let sent = await transport.requests
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.allHTTPHeaderFields, ["Authorization": "Bearer \(Self.token)"])
    }

    func testWeakIfNoneMatchIsSentVerbatim() async throws {
        let transport = FakeHTTPTransport(status: 304)
        _ = try await makeAPI(transport: transport).fetchPolicy(etag: "W/\"v12\"")
        let sent = await transport.requests
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "W/\"v12\"")
    }

    func testIfNoneMatchWithControlCharactersIsNotSent() async throws {
        let transport = FakeHTTPTransport(status: 304)
        _ = try await makeAPI(transport: transport).fetchPolicy(etag: "\"v3\"\r\nX-Evil: 1")
        let sent = await transport.requests
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.allHTTPHeaderFields, ["Authorization": "Bearer \(Self.token)"])
    }

    func testUrlIsBuiltFromBaseWithTrailingSlashOrPort() async throws {
        let cases = [
            "https://guardian.test/": "https://guardian.test/api/v1/policy",
            "https://guardian.test": "https://guardian.test/api/v1/policy",
            "https://10.0.0.1:8443/": "https://10.0.0.1:8443/api/v1/policy",
            "https://[::1]:8443": "https://[::1]:8443/api/v1/policy",
        ]
        for (base, expected) in cases {
            let transport = FakeHTTPTransport(status: 304)
            _ = try await makeAPI(url: base, transport: transport).fetchPolicy(etag: nil)
            let sent = await transport.requests
            let request = try XCTUnwrap(sent.first)
            XCTAssertEqual(request.url?.absoluteString, expected, base)
        }
    }

    func testSettingsAreReadForEveryRequest() async throws {
        let current = Mutex(AgentSettings(serverURL: URL(string: "https://one.test"), spkiPin: Self.pin))
        let transport = FakeHTTPTransport(status: 304)
        let api = HTTPAgentAPI(settings: { current.withLock { $0 } },
                               secrets: InMemorySecretStore(token: Self.token), transport: transport)
        _ = try await api.fetchPolicy(etag: nil)
        current.withLock { $0.serverURL = URL(string: "https://two.test:9443") }
        _ = try await api.fetchPolicy(etag: nil)
        let urls = await transport.requests.map { $0.url?.absoluteString }
        XCTAssertEqual(urls, ["https://one.test/api/v1/policy", "https://two.test:9443/api/v1/policy"])
    }

    // MARK: - GET /api/v1/policy responses

    func testOk200ReturnsBodyEtagVersion() async throws {
        let body = policyBody()
        let api = makeAPI(transport: FakeHTTPTransport(status: 200, headers: policyHeaders(), body: body))
        let result = try await api.fetchPolicy(etag: nil)
        XCTAssertEqual(result, .modified(body: body, etag: "\"v3\"", version: 3))
    }

    func testBodyIsReturnedByteForByte() async throws {
        let body = Data("{\n  \"rules\": [],\n  \"version\": 7\n}\n".utf8)
        let api = makeAPI(transport: FakeHTTPTransport(status: 200, headers: policyHeaders(etag: "\"v7\""),
                                                       body: body))
        let result = try await api.fetchPolicy(etag: "\"v6\"")
        XCTAssertEqual(result, .modified(body: body, etag: "\"v7\"", version: 7))
    }

    func testWeakEtagIsAccepted() async throws {
        let body = policyBody()
        let api = makeAPI(transport: FakeHTTPTransport(status: 200, headers: policyHeaders(etag: "W/\"v3\""),
                                                       body: body))
        let result = try await api.fetchPolicy(etag: nil)
        XCTAssertEqual(result, .modified(body: body, etag: "W/\"v3\"", version: 3))
    }

    func testEtagSurroundingBlanksAreIgnored() async throws {
        let body = policyBody()
        let api = makeAPI(transport: FakeHTTPTransport(status: 200, headers: policyHeaders(etag: " \"v3\" "),
                                                       body: body))
        let result = try await api.fetchPolicy(etag: nil)
        XCTAssertEqual(result, .modified(body: body, etag: "\"v3\"", version: 3))
    }

    func testLargeVersionRoundTrips() async throws {
        let body = Data(#"{"version":9007199254740993}"#.utf8)
        let api = makeAPI(transport: FakeHTTPTransport(
            status: 200, headers: policyHeaders(etag: "\"v9007199254740993\""), body: body
        ))
        let result = try await api.fetchPolicy(etag: nil)
        XCTAssertEqual(result, .modified(body: body, etag: "\"v9007199254740993\"", version: 9_007_199_254_740_993))
    }

    func testNotModified304() async throws {
        let api = makeAPI(transport: FakeHTTPTransport(status: 304, headers: ["ETag": "\"v3\""]))
        let result = try await api.fetchPolicy(etag: "\"v3\"")
        XCTAssertEqual(result, .notModified)
    }

    func testVersionMismatchWithEtagIsMalformed() async {
        await assertFetch(.malformedResponse, headers: policyHeaders(etag: "\"v4\""), body: policyBody(version: 3))
    }

    func testMissingOrInvalidEtagIsMalformed() async {
        await assertFetch(.malformedResponse, headers: Self.jsonType, body: policyBody())
        let bad = ["v3", "\"v\"", "\"vx\"", "\"v-3\"", "\"v+3\"", "\"3\"", "\"v3", "w/\"v3\"", "W/ \"v3\"",
                   "\"v3\", \"v4\"", "\"v3\"x", "\"v99999999999999999999\"", "\"V3\"", "*", ""]
        for etag in bad {
            await assertFetch(.malformedResponse, headers: policyHeaders(etag: etag), body: policyBody())
        }
    }

    func testInvalidJsonBodyIsMalformed() async {
        let bodies = ["not json", "", "[]", "3", "\"v3\"", "null", #"{}"#, #"{"version":"3"}"#,
                      #"{"version":3.5}"#, #"{"version":3.0}"#, #"{"version":true}"#, #"{"version":null}"#,
                      #"{"version":3"#, #"[{"version":3}]"#]
        for body in bodies {
            await assertFetch(.malformedResponse, headers: policyHeaders(), body: Data(body.utf8))
        }
    }

    func testInvalidUtf8BodyIsMalformed() async {
        var body = Data(#"{"version":3,"x":""#.utf8)
        body.append(contentsOf: [0xFF, 0xFE])
        body.append(contentsOf: Data(#""}"#.utf8))
        await assertFetch(.malformedResponse, headers: policyHeaders(), body: body)
    }

    func testWrongMediaTypeIsMalformed() async {
        let types = ["text/html", "text/plain; charset=utf-8", "application/jsonx", "application/json-patch+json",
                     "application/problem+json", "", "json"]
        for type in types {
            await assertFetch(.malformedResponse, headers: policyHeaders(type: type), body: policyBody())
        }
        await assertFetch(.malformedResponse, headers: ["ETag": "\"v3\""], body: policyBody())
    }

    func testCharsetSuffixIsAccepted() async throws {
        let types = ["application/json; charset=utf-8", "Application/JSON ;charset=UTF-8", " application/json ",
                     "application/json"]
        for type in types {
            let body = policyBody()
            let api = makeAPI(transport: FakeHTTPTransport(status: 200, headers: policyHeaders(type: type),
                                                           body: body))
            let result = try await api.fetchPolicy(etag: nil)
            XCTAssertEqual(result, .modified(body: body, etag: "\"v3\"", version: 3), type)
        }
    }

    private func paddedPolicy(totalBytes: Int) -> Data {
        let head = #"{"version":3,"pad":""#
        let tail = #""}"#
        let padding = String(repeating: "x", count: totalBytes - head.utf8.count - tail.utf8.count)
        return Data((head + padding + tail).utf8)
    }

    func testBodyOverOneMiBIsMalformed() async {
        let body = paddedPolicy(totalBytes: 1_048_577)
        XCTAssertEqual(body.count, 1_048_577)
        await assertFetch(.malformedResponse, headers: policyHeaders(), body: body)
    }

    func testBodyOfExactlyOneMiBIsAccepted() async throws {
        let body = paddedPolicy(totalBytes: 1_048_576)
        let api = makeAPI(transport: FakeHTTPTransport(status: 200, headers: policyHeaders(), body: body))
        let result = try await api.fetchPolicy(etag: nil)
        XCTAssertEqual(result, .modified(body: body, etag: "\"v3\"", version: 3))
    }
}
