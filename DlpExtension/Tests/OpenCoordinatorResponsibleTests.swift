import XCTest

private typealias Fixture = CoordinatorFixture

/// A responsible process that is the opener itself is taken from the ES message, not resolved.
final class OpenCoordinatorResponsibleTests: XCTestCase {
    func testResponsibleThatIsTheOpenerSkipsTheResolver() async throws {
        // The resolver would map the token to an allowed identity: it must not be consulted at all.
        let rig = try OpenCoordinatorRig.make(resolver: FakeResolver([Fixture.claudeToken: Fixture.cat]))
        var responses = rig.responses.stream.makeAsyncIterator()
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.claude, responsibleIsProcess: true)
        let response = await responses.next()
        XCTAssertEqual(response, .deny)
        let event = await events.next()
        XCTAssertEqual(event?.decision, .deny)
        XCTAssertEqual(event?.responsible, Fixture.claude, "the opener's kernel identity is the responsible one")
        XCTAssertEqual(rig.resolver.calls, 0)
    }

    func testResponsibleIsProcessWinsOverAToken() async throws {
        let rig = try OpenCoordinatorRig.make(resolver: FakeResolver([Fixture.claudeToken: Fixture.claude]))
        var events = rig.queue.updates.makeAsyncIterator()
        rig.handle(process: Fixture.cat, responsible: Fixture.claudeToken, responsibleIsProcess: true)
        let event = await events.next()
        XCTAssertEqual(event?.decision, .allow)
        XCTAssertEqual(event?.responsible, Fixture.cat)
        XCTAssertEqual(rig.resolver.calls, 0)
    }
}
