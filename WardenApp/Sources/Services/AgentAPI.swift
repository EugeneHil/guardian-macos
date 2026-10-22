import Foundation

enum PolicyFetchResult: Equatable, Sendable {
    /// `body` is the server's policy text byte for byte; `etag` is the `ETag` header value (trimmed) to send back
    /// as `If-None-Match`; `version` equals both the N in `"vN"` and the body's `version` field.
    case modified(body: Data, etag: String, version: Int64)
    case notModified
}

/// Failures of the agent API. No case carries the token, a URL, a query or response body text.
enum AgentAPIError: Error, Equatable {
    /// Server URL, pin or token missing or invalid (also when the Keychain cannot hand out the token).
    case notConfigured
    case unauthorized
    case throttled(retryAfter: Duration)
    case invalidBatch
    /// The request body is over the server's 1 MiB limit (`413`, or caught before sending): split the batch.
    case payloadTooLarge
    /// Any status the contract does not map otherwise (5xx, and unexpected statuses such as 404 or 405).
    case server(Int)
    case transport
    case pinMismatch
    case malformedResponse
}

protocol AgentAPI: Sendable {
    func fetchPolicy(etag: String?) async throws -> PolicyFetchResult
    func postEvents(_ events: [AccessEvent]) async throws
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
