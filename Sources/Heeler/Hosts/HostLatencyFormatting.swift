import Foundation

/// The one rounding rule for a Host's measured `ping` round trip. The Hosts
/// sheet chip and Agent detail's telemetry label both render through it, so
/// the same measurement can never read as two different numbers depending on
/// which surface the user is looking at.
enum HostLatencyFormatting {
    /// Integer milliseconds, or `<1 ms` below the first one — an integer
    /// there would round to a zero the measurement does not support.
    static func formatted(_ latency: Duration) -> String {
        guard let milliseconds = roundedMilliseconds(latency) else { return "<1 ms" }
        return "\(milliseconds) ms"
    }

    /// The same value spelled for VoiceOver, which reads `ms` as letters.
    static func spoken(_ latency: Duration) -> String {
        guard let milliseconds = roundedMilliseconds(latency) else {
            return "Less than 1 millisecond"
        }
        return "\(milliseconds) millisecond\(milliseconds == 1 ? "" : "s")"
    }

    /// Nil below one millisecond. A negative measurement — a clock that moved
    /// under the sample — clamps to zero rather than rendering backwards.
    private static func roundedMilliseconds(_ latency: Duration) -> Int? {
        let components = latency.components
        let milliseconds = max(
            0,
            Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000)
        guard milliseconds >= 1 else { return nil }
        return Int(milliseconds.rounded())
    }
}
