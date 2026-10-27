import Foundation
import Security
import Synchronization
import XCTest

/// Protection space carrying a server trust, as the URL loading system builds it for a TLS handshake.
private final class TrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust?

    init(trust: SecTrust?, method: String = NSURLAuthenticationMethodServerTrust) {
        self.trust = trust
        super.init(host: "guardian.test", port: 8443, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
                   authenticationMethod: method)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var serverTrust: SecTrust? {
        trust
    }
}

private final class NullChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
    func cancel(_: URLAuthenticationChallenge) {}
}

final class PinnedURLSessionTests: XCTestCase {
    private let pin = Data(repeating: 7, count: 32).base64EncodedString()
    private let otherPin = Data(repeating: 8, count: 32).base64EncodedString()

    private func challenge(_ space: URLProtectionSpace) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                   failureResponse: nil, error: nil, sender: NullChallengeSender())
    }

    // MARK: - PinPolicy

    func testPinPolicyAcceptsOnlyMatchingServerTrust() {
        let trust = NSURLAuthenticationMethodServerTrust
        XCTAssertEqual(PinPolicy.decide(authenticationMethod: trust, leafPin: pin, expectedPin: pin), .accept)
        XCTAssertEqual(PinPolicy.decide(authenticationMethod: trust, leafPin: otherPin, expectedPin: pin), .rejectPin)
        XCTAssertEqual(PinPolicy.decide(authenticationMethod: trust, leafPin: nil, expectedPin: pin), .rejectPin)
        XCTAssertEqual(PinPolicy.decide(authenticationMethod: trust, leafPin: pin, expectedPin: ""), .rejectPin)
        XCTAssertEqual(PinPolicy.decide(authenticationMethod: trust, leafPin: "", expectedPin: ""), .rejectPin)
    }

    func testPinPolicyRejectsTheProtectionSpaceForEveryOtherMethod() {
        let methods = [
            NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodClientCertificate,
            NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate,
            NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodHTMLForm, "Bearer", "unknown",
        ]
        for method in methods {
            XCTAssertEqual(PinPolicy.decide(authenticationMethod: method, leafPin: pin, expectedPin: pin),
                           .rejectProtectionSpace, method)
        }
    }

    // MARK: - Delegate (the URLSession boundary)

    func testGeneratedCertificateHashesToItsSpkiPin() throws {
        let made = try TestCertificate.make()
        XCTAssertEqual(SPKIPin.hash(of: made.certificate), made.expectedPin)
    }

    func testDelegateAcceptsMatchingPinWithTrustCredential() async throws {
        let made = try TestCertificate.make()
        let expected = made.expectedPin
        let delegate = PinningDelegate(expectedPin: { expected })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (disposition, credential) = await delegate.urlSession(
            session, didReceive: challenge(TrustProtectionSpace(trust: made.trust))
        )
        XCTAssertEqual(disposition, .useCredential)
        XCTAssertNotNil(credential)
        XCTAssertFalse(delegate.pinRejected)
    }

    func testDelegateRejectsWrongPinAndRecordsIt() async throws {
        let made = try TestCertificate.make()
        let wrong = otherPin
        let delegate = PinningDelegate(expectedPin: { wrong })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (disposition, credential) = await delegate.urlSession(
            session, didReceive: challenge(TrustProtectionSpace(trust: made.trust))
        )
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
        XCTAssertTrue(delegate.pinRejected)
    }

    func testDelegateReadsThePinForEveryChallenge() async throws {
        let made = try TestCertificate.make()
        let current = Mutex(otherPin)
        let delegate = PinningDelegate(expectedPin: { current.withLock { $0 } })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let space = TrustProtectionSpace(trust: made.trust)
        let first = await delegate.urlSession(session, didReceive: challenge(space))
        XCTAssertEqual(first.0, .cancelAuthenticationChallenge)
        current.withLock { $0 = made.expectedPin }
        let second = await delegate.urlSession(session, didReceive: challenge(space))
        XCTAssertEqual(second.0, .useCredential)
    }

    func testDelegateRejectsServerTrustChallengeWithoutTrust() async {
        let expected = pin
        let delegate = PinningDelegate(expectedPin: { expected })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (disposition, credential) = await delegate.urlSession(
            session, didReceive: challenge(TrustProtectionSpace(trust: nil))
        )
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
        XCTAssertTrue(delegate.pinRejected)
    }

    func testDelegateRejectsOtherProtectionSpacesWithoutRecordingPinRejection() async throws {
        let made = try TestCertificate.make()
        let expected = made.expectedPin
        let delegate = PinningDelegate(expectedPin: { expected })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = try session.dataTask(with: URLRequest(url: XCTUnwrap(URL(string: "https://guardian.test"))))
        let space = TrustProtectionSpace(trust: made.trust, method: NSURLAuthenticationMethodHTTPBasic)
        let sessionLevel = await delegate.urlSession(session, didReceive: challenge(space))
        let taskLevel = await delegate.urlSession(session, task: task, didReceive: challenge(space))
        XCTAssertEqual(sessionLevel.0, .rejectProtectionSpace)
        XCTAssertNil(sessionLevel.1)
        XCTAssertEqual(taskLevel.0, .rejectProtectionSpace)
        XCTAssertNil(taskLevel.1)
        XCTAssertFalse(delegate.pinRejected)
    }

    func testDelegateTaskLevelChallengeUsesThePin() async throws {
        let made = try TestCertificate.make()
        let expected = made.expectedPin
        let delegate = PinningDelegate(expectedPin: { expected })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = try session.dataTask(with: URLRequest(url: XCTUnwrap(URL(string: "https://guardian.test"))))
        let result = await delegate.urlSession(session, task: task,
                                               didReceive: challenge(TrustProtectionSpace(trust: made.trust)))
        XCTAssertEqual(result.0, .useCredential)
    }

    func testDelegateRefusesRedirects() async throws {
        let delegate = PinningDelegate(expectedPin: { "" })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://guardian.test/api/v1/policy"))
        let task = session.dataTask(with: URLRequest(url: url))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Location": "https://evil.test/"]))
        let next = try URLRequest(url: XCTUnwrap(URL(string: "https://evil.test/")))
        let followed = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                 newRequest: next)
        XCTAssertNil(followed)
    }

    // MARK: - Session configuration and error mapping

    func testConfigurationDisablesCachesCookiesAndCredentials() {
        let configuration = PinnedURLSession.makeConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 15)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.tlsMinimumSupportedProtocolVersion, .TLSv12)
        XCTAssertNil(configuration.httpAdditionalHeaders)
    }

    func testPreparedRequestIsUncachedCookielessAndTimesOut() throws {
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://guardian.test/api/v1/policy")))
        request.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        let prepared = PinnedURLSession.prepare(request)
        XCTAssertEqual(prepared.timeoutInterval, 15)
        XCTAssertEqual(prepared.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(prepared.httpShouldHandleCookies)
        XCTAssertEqual(prepared.allHTTPHeaderFields, ["Authorization": "Bearer x"])
    }

    func testCancelledChallengeMapsToPinMismatchOnlyAfterARejection() {
        XCTAssertEqual(PinnedURLSession.mapError(URLError(.cancelled), pinRejected: true) as? AgentAPIError,
                       .pinMismatch)
        XCTAssertEqual(PinnedURLSession.mapError(URLError(.secureConnectionFailed), pinRejected: true)
            as? AgentAPIError, .pinMismatch)
        XCTAssertEqual(PinnedURLSession.mapError(URLError(.cancelled), pinRejected: false) as? AgentAPIError,
                       .transport)
        XCTAssertEqual(PinnedURLSession.mapError(URLError(.timedOut), pinRejected: false) as? AgentAPIError,
                       .transport)
        XCTAssertEqual(PinnedURLSession.mapError(URLError(.serverCertificateUntrusted), pinRejected: false)
            as? AgentAPIError, .transport)
        XCTAssertEqual(PinnedURLSession.mapError(AgentAPIError.malformedResponse, pinRejected: false)
            as? AgentAPIError, .malformedResponse)
        XCTAssertTrue(PinnedURLSession.mapError(CancellationError(), pinRejected: false) is CancellationError)
    }

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

    func testCancelledTaskMapsToCancellationError() async {
        let error = await errorInCancelledTask {
            throw PinnedURLSession.mapError(URLError(.cancelled), pinRejected: false)
        }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let other = await errorInCancelledTask {
            throw PinnedURLSession.mapError(URLError(.timedOut), pinRejected: true)
        }
        XCTAssertTrue(other is CancellationError, "\(String(describing: other))")
    }

    // MARK: - Body limit

    private func bytes(_ count: Int) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for index in 0 ..< count {
                continuation.yield(UInt8(index & 0x7F))
            }
            continuation.finish()
        }
    }

    func testBodyWithinLimitIsCollected() async throws {
        let body = try await PinnedURLSession.collectBody(bytes(10), expectedLength: -1, limit: 10)
        XCTAssertEqual(body, Data((0 ..< 10).map { UInt8($0) }))
        let empty = try await PinnedURLSession.collectBody(bytes(0), expectedLength: 0, limit: 10)
        XCTAssertEqual(empty, Data())
    }

    func testBodyOverLimitIsRejectedWhileStreaming() async {
        do {
            _ = try await PinnedURLSession.collectBody(bytes(11), expectedLength: -1, limit: 10)
            XCTFail("expected malformedResponse")
        } catch {
            XCTAssertEqual(error as? AgentAPIError, .malformedResponse)
        }
    }

    func testDeclaredLengthOverLimitIsRejectedBeforeReading() async {
        do {
            _ = try await PinnedURLSession.collectBody(bytes(0), expectedLength: 11, limit: 10)
            XCTFail("expected malformedResponse")
        } catch {
            XCTAssertEqual(error as? AgentAPIError, .malformedResponse)
        }
        XCTAssertEqual(PinnedURLSession.maxBodyBytes, 1_048_576)
    }

    // MARK: - Real URLSession path (no external network)

    private func transport() -> PinnedURLSession {
        let expected = pin
        return PinnedURLSession(settings: { AgentSettings(serverURL: nil, spkiPin: expected) })
    }

    func testClosedLoopbackPortIsTransportError() async throws {
        let request = try URLRequest(url: XCTUnwrap(URL(string: "https://127.0.0.1:1/api/v1/policy")))
        do {
            _ = try await transport().send(request)
            XCTFail("expected transport")
        } catch {
            XCTAssertEqual(error as? AgentAPIError, .transport)
        }
    }

    func testRealSendInCancelledTaskIsCancellation() async throws {
        let request = try URLRequest(url: XCTUnwrap(URL(string: "https://127.0.0.1:1/api/v1/policy")))
        let session = transport()
        let error = await errorInCancelledTask { _ = try await session.send(request) }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
    }

    func testNonHTTPResponseIsTransportError() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await transport().send(URLRequest(url: file))
            XCTFail("expected transport")
        } catch {
            XCTAssertEqual(error as? AgentAPIError, .transport)
        }
    }
}
