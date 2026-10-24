/// Converts an Endpoint Security message deadline (mach absolute time) into the time left to answer it.
enum ESDeadline {
    /// Upper bound of the reported time left: the watchdog then allows at most `cap / 2` after the event, so a
    /// generous kernel deadline cannot make a stuck evaluation hold an open for long.
    static let cap: Duration = .seconds(2)

    /// `deadline - now` in ticks, scaled by the mach timebase (`ticks * numer / denom` nanoseconds), clamped to
    /// `0...cap`. Overflow-safe for any input; an invalid timebase yields zero (answer at once, i.e. allow).
    static func remaining(deadline: UInt64, now: UInt64, timebase: (numer: UInt32, denom: UInt32)) -> Duration {
        guard deadline > now, timebase.numer > 0, timebase.denom > 0 else { return .zero }
        let ticks = deadline - now
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        let denom = UInt64(timebase.denom)
        // The quotient does not fit in 64 bits exactly when the high word is at least the divisor.
        guard product.high < denom else { return cap }
        let nanoseconds = denom.dividingFullWidth(product).quotient
        let capNanoseconds = UInt64(cap.components.seconds) * 1_000_000_000
        guard nanoseconds < capNanoseconds else { return cap }
        return .nanoseconds(Int64(nanoseconds))
    }
}
