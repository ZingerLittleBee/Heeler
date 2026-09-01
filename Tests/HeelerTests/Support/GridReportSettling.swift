import Testing

/// The settle wait ran out of polls. Which way it ran out matters: no report
/// ever arrived is a terminal that never measured a grid — or a freeze still
/// holding one back — while reports that kept changing is a layout that never
/// came to rest. Reporting them as one error sent #263 looking for a stalled
/// engine when the freeze itself was the question.
enum GridReportsNeverSettledError: Error, CustomStringConvertible {
    case noReportArrived
    case reportsKeptChanging(count: Int)

    var description: String {
        switch self {
        case .noReportArrived:
            "no grid report ever arrived"
        case .reportsKeptChanging(let count):
            "grid reports never went quiet (\(count) so far)"
        }
    }
}

/// Waits until grid reports have arrived *and* gone quiet. Quiet alone is
/// not settlement: the report a thaw schedules rides two timers, so on a
/// loaded machine 200ms of silence can elapse before it lands — quiet
/// counting must not start until a report the caller is about to assert
/// on exists (#225). Only proven quiet returns; exhausting the poll cap
/// throws, so a report that never comes or never stops churning fails
/// loud instead of handing the caller a state it cannot trust.
///
/// Prefer ``TerminalGridReportPhaseRecorder`` wherever the freeze's own
/// lifecycle answers the question: this poll infers a phase from report
/// timing, which is Ghostty's to decide and no runner's to promise.
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
    throw count() == 0
        ? GridReportsNeverSettledError.noReportArrived
        : GridReportsNeverSettledError.reportsKeptChanging(count: count())
}
