import Testing

/// The settle wait ran out of polls with the reports still absent or
/// still churning; the caller's assertions cannot trust the state.
struct GridReportsNeverSettledError: Error {}

/// Waits until grid reports have arrived *and* gone quiet. Quiet alone is
/// not settlement: the report a thaw schedules rides two timers, so on a
/// loaded machine 200ms of silence can elapse before it lands — quiet
/// counting must not start until a report the caller is about to assert
/// on exists (#225). Only proven quiet returns; exhausting the poll cap
/// throws, so a report that never comes or never stops churning fails
/// loud instead of handing the caller a state it cannot trust.
@MainActor
func waitForGridReportsToSettle(count: () -> Int) async throws {
    var stablePolls = 0
    var previousCount = count()
    for _ in 0..<1000 {
        try await Task.sleep(for: .milliseconds(10))
        if count() == previousCount, count() > 0 {
            stablePolls += 1
            if stablePolls >= 20 { return }
        } else {
            previousCount = count()
            stablePolls = 0
        }
    }
    throw GridReportsNeverSettledError()
}
