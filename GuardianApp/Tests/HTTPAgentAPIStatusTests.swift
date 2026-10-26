import Foundation
import XCTest

final class HTTPAgentAPIStatusTests: AgentAPITestCase {
    // MARK: - Status mapping, both endpoints

    func testStatus401Unauthorized() async {
        await assertFetch(.unauthorized, status: 401, headers: Self.jsonType)
        await assertPost(.unauthorized, status: 401)
    }

    func testStatus429UsesRetryAfter() async {
        await assertFetch(.throttled(retryAfter: .seconds(120)), status: 429, headers: ["Retry-After": "120"])
        await assertPost(.throttled(retryAfter: .seconds(45)), status: 429, headers: ["Retry-After": "45"])
    }

    func test429WithoutHeaderDefaultsTo60s() async {
        await assertFetch(.throttled(retryAfter: .seconds(60)), status: 429)
        await assertPost(.throttled(retryAfter: .seconds(60)), status: 429)
    }

    func testRetryAfterGarbageHugeAndDateForms() async {
        let cases: [(String, Int64)] = [
            ("abc", 60), ("", 60), ("-5", 60), ("+5", 60), ("1.5", 60), ("Wed, 21 Oct 2026 07:28:00 GMT", 60),
            ("99999999999999999999999", 3600), ("7200", 3600), ("3600", 3600), ("0", 1), (" 30 ", 30),
            ("1", 1), ("٣", 60),
        ]
        for (header, seconds) in cases {
            await assertFetch(.throttled(retryAfter: .seconds(seconds)), status: 429,
                              headers: ["Retry-After": header])
        }
    }

    func testStatus503IsServerError() async {
        await assertFetch(.server(503), status: 503, headers: Self.jsonType)
        await assertFetch(.server(500), status: 500)
        await assertPost(.server(503), status: 503)
        await assertPost(.server(500), status: 500)
    }

    func testStatus400OnPolicyIsServerError() async {
        await assertFetch(.server(400), status: 400, headers: Self.jsonType)
    }

    func testUnexpectedStatusesMapToServer() async {
        for status in [204, 302, 404, 405] {
            await assertFetch(.server(status), status: status)
            await assertPost(.server(status), status: status)
        }
        await assertPost(.server(304), status: 304)
    }

    func test413IsPayloadTooLarge() async {
        await assertPost(.payloadTooLarge, status: 413)
        await assertFetch(.payloadTooLarge, status: 413)
    }

    // MARK: - Request body limit

    /// Events whose upload payload is exactly `target` bytes (file names padded with ASCII, at most 4096 bytes each).
    private static func events(encodingTo target: Int) throws -> [AccessEvent] {
        let count = target / 4000 + 1
        let base = try AccessEvent.uploadPayload((0 ..< count).map { _ in event(file: "/") }).count
        var extra = target - base
        return (0 ..< count).map { _ in
            let pad = min(extra, 4095)
            extra -= pad
            return event(file: "/" + String(repeating: "x", count: pad))
        }
    }

    func testPayloadOfExactlyOneMiBIsSent() async throws {
        let events = try Self.events(encodingTo: 1_048_576)
        XCTAssertEqual(try AccessEvent.uploadPayload(events).count, 1_048_576)
        let transport = FakeHTTPTransport(status: 200)
        try await makeAPI(transport: transport).postEvents(events)
        let sent = await transport.requests
        XCTAssertEqual(sent.first?.httpBody?.count, 1_048_576)
    }

    func testOversizedPayloadIsRejectedWithoutARequest() async throws {
        let events = try Self.events(encodingTo: 1_048_577)
        XCTAssertEqual(try AccessEvent.uploadPayload(events).count, 1_048_577)
        let transport = FakeHTTPTransport(status: 200)
        let error = await postError(makeAPI(transport: transport), events)
        XCTAssertEqual(error as? AgentAPIError, .payloadTooLarge)
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 0)
    }

    // MARK: - Configuration

    func testMissingTokenIsNotConfigured() async {
        let cases: [(any SecretStoring, String)] = [
            (InMemorySecretStore(token: nil), "nil"),
            (InMemorySecretStore(token: ""), "empty"),
            (InMemorySecretStore(token: Self.token + "\n"), "newline"),
            (InMemorySecretStore(token: "Bearer-ish"), "garbage"),
            (FailingSecretStore(), "keychain failure"),
        ]
        for (store, label) in cases {
            let transport = FakeHTTPTransport(status: 304)
            let api = makeAPI(secrets: store, transport: transport)
            let fetch = await fetchError(api)
            XCTAssertEqual(fetch as? AgentAPIError, .notConfigured, label)
            let post = await postError(api)
            XCTAssertEqual(post as? AgentAPIError, .notConfigured, label)
            let sent = await transport.requests.count
            XCTAssertEqual(sent, 0, label)
        }
    }

    func testMissingOrInvalidServerSettingsAreNotConfigured() async {
        let cases: [(String?, String)] = [
            (nil, Self.pin), ("http://guardian.test", Self.pin), ("https://guardian.test/base", Self.pin),
            ("https://guardian.test/?q=1", Self.pin), ("https://user:pw@guardian.test", Self.pin),
            ("https://guardian.test", ""), ("https://guardian.test", "not-a-pin"),
        ]
        for (url, pin) in cases {
            let transport = FakeHTTPTransport(status: 304)
            let api = makeAPI(url: url, pin: pin, transport: transport)
            let fetch = await fetchError(api)
            XCTAssertEqual(fetch as? AgentAPIError, .notConfigured, url ?? "nil")
            let post = await postError(api)
            XCTAssertEqual(post as? AgentAPIError, .notConfigured, url ?? "nil")
            let sent = await transport.requests.count
            XCTAssertEqual(sent, 0, url ?? "nil")
        }
    }

    // MARK: - POST /api/v1/events

    func testPostEventsSendsBatchBody() async throws {
        let transport = FakeHTTPTransport(status: 200, headers: Self.jsonType, body: Data(#"{"accepted":2}"#.utf8))
        let events = [Self.event(), Self.event(file: "/Users/alice/b.txt")]
        try await makeAPI(transport: transport).postEvents(events)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://guardian.test:8443/api/v1/events")
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "Authorization": "Bearer \(Self.token)",
            "Content-Type": "application/json",
        ])
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(body, try AccessEvent.uploadPayload(events))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["file"] as? String, "/Users/alice/report.pdf")
        XCTAssertEqual(decoded[1]["file"] as? String, "/Users/alice/b.txt")
        XCTAssertEqual(decoded[0]["decision"] as? String, "deny")
        XCTAssertEqual(decoded[0]["ruleId"] as? String, "block-docs")
        XCTAssertEqual(decoded[0]["ts"] as? String, "2026-10-21T08:30:00Z")
    }

    func testPostUrlIgnoresTrailingSlash() async throws {
        let transport = FakeHTTPTransport(status: 200)
        try await makeAPI(url: "https://10.0.0.1:8443/", transport: transport).postEvents([Self.event()])
        let sent = await transport.requests
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.url?.absoluteString, "https://10.0.0.1:8443/api/v1/events")
    }

    func testPost400IsInvalidBatch() async {
        await assertPost(.invalidBatch, status: 400)
    }

    func testPostEmptyIsNoOp() async throws {
        let transport = FakeHTTPTransport(status: 500)
        try await makeAPI(transport: transport).postEvents([])
        try await makeAPI(url: nil, secrets: InMemorySecretStore(token: nil), transport: transport).postEvents([])
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 0)
    }

    // MARK: - Transport errors

    func testPinMismatchSurfaces() async {
        let fetch = await fetchError(makeAPI(transport: FakeHTTPTransport(error: AgentAPIError.pinMismatch)))
        XCTAssertEqual(fetch as? AgentAPIError, .pinMismatch)
        let post = await postError(makeAPI(transport: FakeHTTPTransport(error: AgentAPIError.pinMismatch)))
        XCTAssertEqual(post as? AgentAPIError, .pinMismatch)
    }

    func testCancelledUrlErrorWithoutPinRejectionIsTransport() async {
        let errors: [any Error & Sendable] = [URLError(.cancelled), URLError(.timedOut),
                                              URLError(.cannotConnectToHost), CocoaError(.fileReadUnknown)]
        for error in errors {
            let fetch = await fetchError(makeAPI(transport: FakeHTTPTransport(error: error)))
            XCTAssertEqual(fetch as? AgentAPIError, .transport, "\(error)")
            let post = await postError(makeAPI(transport: FakeHTTPTransport(error: error)))
            XCTAssertEqual(post as? AgentAPIError, .transport, "\(error)")
        }
    }

    func testTransportAgentErrorsPassThrough() async {
        let fetch = await fetchError(makeAPI(transport: FakeHTTPTransport(error: AgentAPIError.malformedResponse)))
        XCTAssertEqual(fetch as? AgentAPIError, .malformedResponse)
    }

    /// Runs `body` in a task that is cancelled before `body` starts and returns the error it throws.
    private func errorInCancelledTask(_ body: @escaping @Sendable () async throws -> Void) async -> (any Error)? {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await body()
        }
        if case let .failure(error) = await task.result {
            return error
        }
        return nil
    }

    func testCancelledTaskSurfacesCancellationNotTransport() async {
        let api = makeAPI(transport: FakeHTTPTransport(error: URLError(.cancelled)))
        let fetch = await errorInCancelledTask { _ = try await api.fetchPolicy(etag: nil) }
        XCTAssertTrue(fetch is CancellationError, "\(String(describing: fetch))")
        let post = await errorInCancelledTask { try await api.postEvents([Self.event()]) }
        XCTAssertTrue(post is CancellationError, "\(String(describing: post))")
    }

    func testCancelledSecretReadIsNotNotConfigured() async {
        let transport = FakeHTTPTransport(status: 304)
        let api = makeAPI(secrets: FailingSecretStore(error: CancellationError()), transport: transport)
        let fetch = await fetchError(api)
        XCTAssertTrue(fetch is CancellationError, "\(String(describing: fetch))")
        let post = await postError(api)
        XCTAssertTrue(post is CancellationError, "\(String(describing: post))")
        let sent = await transport.requests.count
        XCTAssertEqual(sent, 0)
    }

    func testCancellationErrorPropagates() async {
        let fetch = await fetchError(makeAPI(transport: FakeHTTPTransport(error: CancellationError())))
        XCTAssertTrue(fetch is CancellationError)
    }

    // MARK: - Secrets never leak

    func testErrorsNeverContainToken() async {
        var errors: [any Error] = []
        for status in [204, 400, 401, 404, 413, 429, 500, 503] {
            let headers = ["Retry-After": "5", "WWW-Authenticate": "Bearer"]
            let body = Data(#"{"error":"x","message":"\#(Self.token)"}"#.utf8)
            let api = makeAPI(transport: FakeHTTPTransport(status: status, headers: headers, body: body))
            await fetchError(api).map { errors.append($0) }
            await postError(api).map { errors.append($0) }
        }
        let leaky = Data(#"{"version":"\#(Self.token)"}"#.utf8)
        await fetchError(makeAPI(transport: FakeHTTPTransport(status: 200, headers: policyHeaders(), body: leaky)))
            .map { errors.append($0) }
        await fetchError(makeAPI(transport: FakeHTTPTransport(error: URLError(.timedOut))))
            .map { errors.append($0) }
        await fetchError(makeAPI(url: nil, transport: FakeHTTPTransport())).map { errors.append($0) }
        XCTAssertEqual(errors.count, 19)
        for error in errors {
            for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
                XCTAssertFalse(text.contains(Self.token), text)
                XCTAssertFalse(text.contains("wdn_"), text)
                XCTAssertFalse(text.contains("guardian.test"), text)
            }
        }
    }

    func testTokenAppearsOnlyInAuthorizationHeader() async throws {
        let transport = FakeHTTPTransport(status: 200)
        let api = makeAPI(transport: transport)
        _ = try? await api.fetchPolicy(etag: "\"v1\"")
        try await api.postEvents([Self.event()])
        for request in await transport.requests {
            XCTAssertFalse(request.url?.absoluteString.contains(Self.token) ?? true)
            for (name, value) in request.allHTTPHeaderFields ?? [:] where name != "Authorization" {
                XCTAssertFalse(value.contains(Self.token), name)
            }
            let body = request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            XCTAssertFalse(body.contains(Self.token))
        }
    }
}
