import Foundation
import Synchronization
import XCTest

private final class FakeNotificationPoster: NotificationPosting {
    struct Post: Equatable {
        let process: String
        let file: String
    }

    private let state = Mutex<[Post]>([])

    var posts: [Post] {
        state.withLock { $0 }
    }

    func requestAuthorization() async {}

    func postBlock(process: String, file: String) async {
        state.withLock { $0.append(Post(process: process, file: file)) }
    }
}

final class BlockNotifierTests: XCTestCase {
    private static func event(_ decision: AccessDecision, file: String, ruleId: String? = "r1") -> AccessEvent {
        AccessEvent(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            process: ProcessIdentity(path: "/usr/bin/curl", signingId: "com.apple.curl", teamId: ""),
            responsible: nil, file: file, decision: decision, ruleId: ruleId
        )
    }

    private static func stream(_ events: [AccessEvent]) -> AsyncStream<AccessEvent> {
        AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func testPostsOnlyForDeny() async {
        let poster = FakeNotificationPoster()
        let notifier = BlockNotifier(poster: poster)
        await notifier.run(events: Self.stream([
            Self.event(.deny, file: "/a/one.key"),
            Self.event(.allow, file: "/a/two.key"), // late deny overridden by the watchdog: still not a block
            Self.event(.allow, file: "/a/three.txt", ruleId: nil),
            Self.event(.deny, file: "/a/four.pem"),
        ]))
        XCTAssertEqual(poster.posts.map(\.file), ["one.key", "four.pem"])
    }

    func testBodyContainsFileNameNotFullPath() async {
        let poster = FakeNotificationPoster()
        await BlockNotifier(poster: poster).run(events: Self.stream([Self.event(.deny, file: "/Users/a/proj/.env")]))
        XCTAssertEqual(poster.posts, [.init(process: "curl", file: ".env")])

        let message = BlockMessage(process: "/usr/bin/curl", file: "/Users/a/proj/.env")
        XCTAssertEqual(message.title, "Access blocked")
        XCTAssertEqual(message.body, "curl was blocked from opening .env")
        XCTAssertFalse(message.body.contains("/"))
    }
}
