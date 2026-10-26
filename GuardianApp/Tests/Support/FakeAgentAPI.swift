import Foundation
import Synchronization

/// Scripted `AgentAPI`: results are consumed in order, the last one repeats.
final class FakeAgentAPI: AgentAPI, Sendable {
    typealias PostHandler = @Sendable ([AccessEvent]) throws -> Void

    private struct State {
        var fetchScript: [Result<PolicyFetchResult, AgentAPIError>] = []
        var fetchEtags: [String?] = []
        var postHandler: PostHandler = { _ in }
        var postedBatches: [[AccessEvent]] = []
    }

    private let state = Mutex(State())
    let fetchCalls = CallLatch()
    let postCalls = CallLatch()

    func script(_ results: Result<PolicyFetchResult, AgentAPIError>...) {
        state.withLock { $0.fetchScript = results }
    }

    func setPostHandler(_ handler: @escaping PostHandler) {
        state.withLock { $0.postHandler = handler }
    }

    var fetchEtags: [String?] {
        state.withLock { $0.fetchEtags }
    }

    var postedBatches: [[AccessEvent]] {
        state.withLock { $0.postedBatches }
    }

    func fetchPolicy(etag: String?) async throws -> PolicyFetchResult {
        let result = state.withLock { state -> Result<PolicyFetchResult, AgentAPIError> in
            state.fetchEtags.append(etag)
            if state.fetchScript.count > 1 {
                return state.fetchScript.removeFirst()
            }
            return state.fetchScript.first ?? .success(.notModified)
        }
        fetchCalls.increment()
        return try result.get()
    }

    func postEvents(_ events: [AccessEvent]) async throws {
        let handler = state.withLock { state -> PostHandler in
            state.postedBatches.append(events)
            return state.postHandler
        }
        postCalls.increment()
        try handler(events)
    }
}
