import XCTest

final class ESDeadlineTests: XCTestCase {
    private let identity: (numer: UInt32, denom: UInt32) = (1, 1)

    func testConvertsMachTicksWithTimebase() {
        let remaining = ESDeadline.remaining(deadline: 10000, now: 7000, timebase: (125, 3))
        XCTAssertEqual(remaining, .nanoseconds(125_000))
    }

    func testPastDeadlineClampsToZero() {
        XCTAssertEqual(ESDeadline.remaining(deadline: 7000, now: 10000, timebase: (125, 3)), .zero)
        XCTAssertEqual(ESDeadline.remaining(deadline: 5, now: 5, timebase: identity), .zero)
    }

    func testHugeDeadlineDoesNotOverflow() {
        XCTAssertEqual(ESDeadline.remaining(deadline: UInt64.max, now: 0, timebase: (125, 3)), ESDeadline.cap)
        XCTAssertEqual(
            ESDeadline.remaining(deadline: UInt64.max, now: 0, timebase: (UInt32.max, 1)), ESDeadline.cap
        )
    }

    func testLongDeadlineIsCapped() {
        XCTAssertEqual(ESDeadline.cap, .seconds(2))
        let tenSeconds: UInt64 = 10_000_000_000
        XCTAssertEqual(ESDeadline.remaining(deadline: tenSeconds, now: 0, timebase: identity), .seconds(2))
    }

    func testDeadlineJustBelowTheCapIsKept() {
        let ticks: UInt64 = 1_999_999_999
        XCTAssertEqual(ESDeadline.remaining(deadline: ticks, now: 0, timebase: identity), .nanoseconds(ticks))
    }

    func testAppleSiliconTimebase() {
        // 24 MHz ticks (timebase 125/3): 24_000_000 ticks are one second.
        let remaining = ESDeadline.remaining(deadline: 124_000_000, now: 100_000_000, timebase: (125, 3))
        XCTAssertEqual(remaining, .seconds(1))
    }

    func testLargeTimebaseNearTheCap() {
        // ticks * numer exceeds 32 bits by far but stays exact.
        let remaining = ESDeadline.remaining(deadline: 1_500_000_000, now: 0, timebase: (UInt32.max, UInt32.max))
        XCTAssertEqual(remaining, .nanoseconds(1_500_000_000))
    }

    func testInvalidTimebaseAnswersNow() {
        XCTAssertEqual(ESDeadline.remaining(deadline: 1000, now: 0, timebase: (1, 0)), .zero)
        XCTAssertEqual(ESDeadline.remaining(deadline: 1000, now: 0, timebase: (0, 1)), .zero)
    }
}
