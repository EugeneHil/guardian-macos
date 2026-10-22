import Foundation

/// Records every request and answers with one scripted response or error.
actor FakeHTTPTransport: HTTPTransport {
    private enum Outcome {
        case respond(status: Int, headers: [String: String], body: Data)
        case fail(any Error & Sendable)
    }

    private(set) var requests: [URLRequest] = []
    private let outcome: Outcome

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        outcome = .respond(status: status, headers: headers, body: body)
    }

    init(error: any Error & Sendable) {
        outcome = .fail(error)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        switch outcome {
        case let .fail(error):
            throw error
        case let .respond(status, headers, body):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: headers)
            else {
                throw URLError(.badServerResponse)
            }
            return (body, response)
        }
    }
}

/// A secret store whose reads always fail, by default like a Keychain item with a stale ACL.
struct FailingSecretStore: SecretStoring {
    var error: any Error & Sendable = KeychainError.reenterToken(-25293)

    func token() async throws -> String? {
        throw error
    }

    func saveToken(_: String) async throws {}

    func deleteToken() async throws {}
}
