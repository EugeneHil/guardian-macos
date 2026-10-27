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

    /// `deadline - now` in nanoseconds, NOT clamped to `cap` (diagnostics: how generous the kernel deadline is).
    /// Saturates at `UInt64.max` instead of overflowing; zero for a past deadline or an invalid timebase.
    static func unclampedNanoseconds(
        deadline: UInt64, now: UInt64, timebase: (numer: UInt32, denom: UInt32)
    ) -> UInt64 {
        guard deadline > now else { return 0 }
        return nanoseconds(ticks: deadline - now, timebase: timebase)
    }

    /// `ticks * numer / denom`, saturating; zero for an invalid timebase.
    static func nanoseconds(ticks: UInt64, timebase: (numer: UInt32, denom: UInt32)) -> UInt64 {
        guard timebase.numer > 0, timebase.denom > 0 else { return 0 }
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        let denom = UInt64(timebase.denom)
        guard product.high < denom else { return UInt64.max }
        return denom.dividingFullWidth(product).quotient
    }
}
