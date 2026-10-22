import Foundation
import XCTest

final class EventRowModelTests: XCTestCase {
    private let home = "/Users/eugene"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private let dotEnv = "." + "env"

    private func event(
        process: String? = nil,
        responsible: String? = nil,
        file: String? = nil,
        decision: AccessDecision = .deny,
        ruleId: String? = "r1",
        age: TimeInterval = 12
    ) -> AccessEvent {
        AccessEvent(
            id: UUID(),
            timestamp: now.addingTimeInterval(-age),
            process: ProcessIdentity(path: process ?? chrome, signingId: "", teamId: ""),
            responsible: responsible.map { ProcessIdentity(path: $0, signingId: "", teamId: "") },
            file: file ?? "/Users/eugene/proj/api/\(dotEnv)",
            decision: decision,
            ruleId: ruleId
        )
    }

    func testDeniedEventShowsBlockedBadge() {
        let model = EventRowModel(event: event(decision: .deny), now: now, home: home)
        XCTAssertEqual(model.badge, .blocked)
        XCTAssertEqual(model.badgeText, "Blocked")
        XCTAssertEqual(model.title, "Google Chrome → \(dotEnv)")
    }

    func testAllowedEventShowsOkBadge() {
        let model = EventRowModel(event: event(decision: .allow, ruleId: "r1"), now: now, home: home)
        XCTAssertEqual(model.badge, .ok)
        XCTAssertEqual(model.badgeText, "Allowed")
    }

    func testSubtitleReplacesHomeWithTilde() {
        let model = EventRowModel(event: event(), now: now, home: home)
        XCTAssertEqual(model.subtitle, "~/proj/api/\(dotEnv) · 12 s ago")
        let outside = EventRowModel(event: event(file: "/Users/eugenex/a"), now: now, home: home)
        XCTAssertTrue(outside.subtitle.hasPrefix("/Users/eugenex/a"))
    }

    func testHelperProcessUsesResponsibleName() {
        let model = EventRowModel(
            event: event(process: "/x/Google Chrome Helper", responsible: chrome),
            now: now,
            home: home
        )
        XCTAssertEqual(model.title, "Google Chrome → \(dotEnv)")
    }

    func testUnresolvedResponsibleKeepsOpenerName() {
        let model = EventRowModel(event: event(process: "/x/curl", responsible: ""), now: now, home: home)
        XCTAssertEqual(model.title, "curl → \(dotEnv)")
    }

    func testRelativeTimeBuckets() {
        XCTAssertEqual(RelativeTime.string(from: now, now: now), "just now")
        XCTAssertEqual(RelativeTime.string(from: now.addingTimeInterval(-12), now: now), "12 s ago")
        XCTAssertEqual(RelativeTime.string(from: now.addingTimeInterval(-180), now: now), "3 min ago")
        XCTAssertEqual(RelativeTime.string(from: now.addingTimeInterval(-7200), now: now), "2 h ago")
        XCTAssertEqual(RelativeTime.string(from: now.addingTimeInterval(-3 * 86400), now: now), "3 d ago")
        XCTAssertEqual(RelativeTime.string(from: now.addingTimeInterval(30), now: now), "just now")
    }

    func testUnknownProcessNameFallsBack() {
        let model = EventRowModel(event: event(process: ""), now: now, home: home)
        XCTAssertEqual(model.title, "Unknown process → \(dotEnv)")
    }

    func testBundleHelperUsesResponsibleName() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Versions/1/Chrome Renderer"
        let model = EventRowModel(event: event(process: helper, responsible: chrome), now: now, home: home)
        XCTAssertEqual(model.title, "Google Chrome → \(dotEnv)")
    }

    func testCurlFromTerminalKeepsOwnName() {
        let model = EventRowModel(
            event: event(
                process: "/usr/bin/curl",
                responsible: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
            ),
            now: now,
            home: home
        )
        XCTAssertEqual(model.title, "curl → \(dotEnv)")
    }

    func testSameExecutableKeepsOwnName() {
        let model = EventRowModel(event: event(process: chrome, responsible: chrome), now: now, home: home)
        XCTAssertEqual(model.title, "Google Chrome → \(dotEnv)")
    }

    func testRelativeTimeBoundaries() {
        func text(_ seconds: TimeInterval) -> String {
            RelativeTime.string(from: now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(text(59), "59 s ago")
        XCTAssertEqual(text(60), "1 min ago")
        XCTAssertEqual(text(3599), "59 min ago")
        XCTAssertEqual(text(3600), "1 h ago")
        XCTAssertEqual(text(86399), "23 h ago")
        XCTAssertEqual(text(86400), "1 d ago")
        XCTAssertEqual(text(-5), "just now")
    }

    func testTrailingSlashInHomeIsTrimmed() {
        let model = EventRowModel(event: event(file: "/Users/eugene/proj/\(dotEnv)"), now: now, home: "/Users/eugene/")
        XCTAssertEqual(model.subtitle, "~/proj/\(dotEnv) · 12 s ago")
    }

    func testEmptyFileDoesNotLeaveDanglingArrow() {
        let model = EventRowModel(event: event(file: ""), now: now, home: home)
        XCTAssertEqual(model.title, "Google Chrome")
    }
}
