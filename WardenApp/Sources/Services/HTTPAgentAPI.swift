import Foundation

/// Agent client for warden-server (`warden-server/docs/api.md`). Settings and the token are read for every call, so a
/// change takes effect without a restart. Errors never carry the token, the URL or response body text, and nothing
/// here logs.
struct HTTPAgentAPI: AgentAPI {
    static let policyPath = "/api/v1/policy"
    static let eventsPath = "/api/v1/events"
    static let maxPolicyBytes = 1_048_576
    static let defaultRetryAfterSeconds: Int64 = 60
    static let maxRetryAfterSeconds: Int64 = 3600

    private let settings: @Sendable () -> AgentSettings
    private let secrets: any SecretStoring
    private let transport: any HTTPTransport

    init(settings: @escaping @Sendable () -> AgentSettings, secrets: any SecretStoring, transport: any HTTPTransport) {
        self.settings = settings
        self.secrets = secrets
        self.transport = transport
    }

    func fetchPolicy(etag: String?) async throws -> PolicyFetchResult {
        var request = try await authorizedRequest(path: Self.policyPath, method: "GET")
        if let etag, Self.isSafeHeaderValue(etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (body, response) = try await send(request)
        switch response.statusCode {
        case 200:
            return try Self.parsePolicy(body: body, response: response)
        case 304:
            return .notModified
        default:
            throw Self.error(for: response)
        }
    }

    func postEvents(_ events: [AccessEvent]) async throws {
        guard !events.isEmpty else {
            return
        }
        var request = try await authorizedRequest(path: Self.eventsPath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let payload = try? AccessEvent.uploadPayload(events) else {
            throw AgentAPIError.invalidBatch
        }
        request.httpBody = payload
        let (_, response) = try await send(request)
        switch response.statusCode {
        case 200:
            return
        case 400:
            throw AgentAPIError.invalidBatch
        default:
            throw Self.error(for: response)
        }
    }

    // MARK: - Request

    private func authorizedRequest(path: String, method: String) async throws -> URLRequest {
        let current = settings()
        guard let url = Self.endpoint(current, path: path), AgentSettings.isCanonicalPin(current.spkiPin) else {
            throw AgentAPIError.notConfigured
        }
        // A Keychain failure (for example a stale ACL after a rebuild) means the token must be entered again.
        let token = try? await secrets.token()
        guard let token, AgentSettings.isValidToken(token) else {
            throw AgentAPIError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The validated base URL has an empty path or "/"; the endpoint path replaces it.
    static func endpoint(_ settings: AgentSettings, path: String) -> URL? {
        guard let base = settings.serverURL, AgentSettings.urlIssue(base.absoluteString) == nil,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        components.path = path
        return components.url
    }

    /// Visible ASCII, space and tab only: a value with CR/LF or non-ASCII is not sent.
    static func isSafeHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 == 0x09 || (0x20 ... 0x7E).contains($0) }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as AgentAPIError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw AgentAPIError.transport
        }
    }

    // MARK: - Response

    static func error(for response: HTTPURLResponse) -> AgentAPIError {
        switch response.statusCode {
        case 401:
            .unauthorized
        case 429:
            .throttled(retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        default:
            .server(response.statusCode)
        }
    }

    /// Integer seconds clamped to 1...3600; missing, non-numeric or HTTP-date values give 60 s.
    static func retryAfter(_ header: String?) -> Duration {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              text.utf8.allSatisfy(isASCIIDigit)
        else {
            return .seconds(defaultRetryAfterSeconds)
        }
        // All digits: only an overflow fails to parse, and that is "very long".
        let seconds = Int64(text) ?? maxRetryAfterSeconds
        return .seconds(min(max(seconds, 1), maxRetryAfterSeconds))
    }

    /// A 200 must be `application/json` (by media type), at most 1 MiB, with `ETag: "vN"` (or `W/"vN"`) and a JSON
    /// object whose integer `version` is N. The body is returned unchanged.
    static func parsePolicy(body: Data, response: HTTPURLResponse) throws -> PolicyFetchResult {
        guard body.count <= maxPolicyBytes,
              isJSONMediaType(response.value(forHTTPHeaderField: "Content-Type")),
              let etag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespaces),
              let tagVersion = etagVersion(etag),
              let bodyVersion = policyVersion(body), bodyVersion == tagVersion
        else {
            throw AgentAPIError.malformedResponse
        }
        return .modified(body: body, etag: etag, version: tagVersion)
    }

    static func isJSONMediaType(_ header: String?) -> Bool {
        guard let header else {
            return false
        }
        let mediaType = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    /// N from `"vN"` or `W/"vN"` (decimal digits that fit an Int64), else nil.
    static func etagVersion(_ tag: String) -> Int64? {
        var rest = Substring(tag)
        if rest.hasPrefix("W/") {
            rest = rest.dropFirst(2)
        }
        guard rest.count >= 4, rest.hasPrefix("\"v"), rest.hasSuffix("\"") else {
            return nil
        }
        let digits = rest.dropFirst(2).dropLast()
        guard digits.utf8.allSatisfy(isASCIIDigit) else {
            return nil
        }
        return Int64(digits)
    }

    /// The integer `version` of a JSON object body; booleans, floats, strings and non-objects give nil.
    static func policyVersion(_ body: Data) -> Int64? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let number = object["version"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber)
        else {
            return nil
        }
        return number.int64Value
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
