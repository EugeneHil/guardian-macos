import Foundation
import Security
import Synchronization

/// HTTPS transport that trusts the server only through the configured SPKI pin (never the system CA store).
///
/// Every request gets its own ephemeral `URLSession` and `PinningDelegate`, so a recorded pin rejection belongs to
/// exactly that request and a pin change in the settings applies to the next handshake. No cache, no cookies, no
/// credential storage, no redirects, 15 s timeouts, response bodies capped at 1 MiB while streaming.
struct PinnedURLSession: HTTPTransport {
    static let maxBodyBytes = 1_048_576
    static let timeout: TimeInterval = 15

    private let settings: @Sendable () -> AgentSettings

    init(settings: @escaping @Sendable () -> AgentSettings) {
        self.settings = settings
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let settings = settings
        let delegate = PinningDelegate(expectedPin: { settings().spkiPin })
        let session = URLSession(configuration: Self.makeConfiguration(), delegate: delegate, delegateQueue: nil)
        // Cancels a body read abandoned at the size cap and releases the delegate (the session retains it).
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: Self.prepare(request))
            guard let http = response as? HTTPURLResponse else {
                throw AgentAPIError.transport
            }
            let body = try await Self.collectBody(bytes, expectedLength: response.expectedContentLength,
                                                  limit: Self.maxBodyBytes)
            return (body, http)
        } catch {
            throw Self.mapError(error, pinRejected: delegate.pinRejected)
        }
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    static func prepare(_ request: URLRequest) -> URLRequest {
        var prepared = request
        prepared.timeoutInterval = timeout
        prepared.cachePolicy = .reloadIgnoringLocalCacheData
        prepared.httpShouldHandleCookies = false
        return prepared
    }

    /// Task cancellation stays `CancellationError`. Otherwise a failure after a recorded pin rejection is
    /// `pinMismatch` (the cancelled challenge surfaces as `URLError.cancelled`); every other `URLError` or unknown
    /// error is `transport`.
    static func mapError(_ error: any Error, pinRejected: Bool) -> any Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        if pinRejected {
            return AgentAPIError.pinMismatch
        }
        if error is AgentAPIError {
            return error
        }
        return AgentAPIError.transport
    }

    /// Reads at most `limit` bytes; a larger declared length or body is `malformedResponse` without reading the rest.
    static func collectBody<S: AsyncSequence>(
        _ bytes: S, expectedLength: Int64, limit: Int
    ) async throws -> Data where S.Element == UInt8 {
        guard expectedLength <= Int64(limit) else {
            throw AgentAPIError.malformedResponse
        }
        var body = Data()
        if expectedLength > 0 {
            body.reserveCapacity(Int(expectedLength))
        }
        for try await byte in bytes {
            guard body.count < limit else {
                throw AgentAPIError.malformedResponse
            }
            body.append(byte)
        }
        return body
    }
}

/// The `URLSession` delegate: the only callback boundary of the transport. Decisions are made by `PinPolicy`.
final class PinningDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    typealias ChallengeAnswer = (URLSession.AuthChallengeDisposition, URLCredential?)

    private let expectedPin: @Sendable () -> String
    private let rejected = Mutex(false)

    /// `expectedPin` is read on every challenge.
    init(expectedPin: @escaping @Sendable () -> String) {
        self.expectedPin = expectedPin
    }

    /// True once a server-trust challenge was refused because of the pin.
    var pinRejected: Bool {
        rejected.withLock { $0 }
    }

    func urlSession(_: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> ChallengeAnswer {
        disposition(for: challenge)
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> ChallengeAnswer {
        disposition(for: challenge)
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest
    ) async -> URLRequest? {
        nil
    }

    private func disposition(for challenge: URLAuthenticationChallenge) -> ChallengeAnswer {
        let space = challenge.protectionSpace
        let trust = space.serverTrust
        let leaf = trust.flatMap { (SecTrustCopyCertificateChain($0) as? [SecCertificate])?.first }
        let decision = PinPolicy.decide(authenticationMethod: space.authenticationMethod,
                                        leafPin: leaf.flatMap(SPKIPin.hash(of:)), expectedPin: expectedPin())
        switch decision {
        case .accept:
            guard let trust else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        case .rejectPin:
            rejected.withLock { $0 = true }
            return (.cancelAuthenticationChallenge, nil)
        case .rejectProtectionSpace:
            return (.rejectProtectionSpace, nil)
        }
    }
}
