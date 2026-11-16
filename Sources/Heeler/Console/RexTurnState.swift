import Foundation

/// What this device knows of one Rex terminal's turns, and so whether its
/// Agent reads Done here (ADR 0054): as on the other kinds, it finished a turn
/// this device has not looked at since, and its record still says idle or
/// done. None of it is written to the Rex server or the machine.
///
/// Rex keeps no turn count, so a finished turn is named by the report that
/// ended it: the foreground that held the terminal then, and when Rex took it.
/// Whether a turn ended between two reports known here is the link's to say.
/// Within one stretch it followed whole (`RexStatusFollow`), its count does,
/// so the same done reported again ends nothing; a done after the working or
/// blocked known here ends one whatever the count, as the working record it
/// would have counted from may have been removed. Across stretches (another
/// connection, a relaunch, a gap in events), a report whose time has not moved
/// is the one already known, and any other done ends a turn: once reports went
/// unheard, a done made again and a new turn's look alike. A program not known
/// to report done ends a turn going from working to idle, as on the other
/// kinds (`HerdrCoreTurnState`).
///
/// A report from another foreground starts over. It is another program's, and
/// none of the last one's turns, nor this device's look at them, are its.
struct RexTurnState: Codable, Equatable, Sendable {
    /// One report: the foreground that held the terminal and the app it named,
    /// and when Rex took it.
    struct Mark: Codable, Equatable, Sendable {
        var processID: Int?
        var program: String?
        var app: String?
        var updatedAt: String?

        init(_ status: RexProgramStatus) {
            processID = status.ownerProcessID
            program = status.ownerName
            app = status.app
            updatedAt = status.updatedAt
        }

        func isSameProgram(as other: Mark) -> Bool {
            processID == other.processID && program == other.program && app == other.app
        }
    }

    struct Report: Codable, Equatable, Sendable {
        var state: String
        var mark: Mark
        var follow: RexStatusFollow?
    }

    /// The last report this device knows of.
    private(set) var last: Report?
    /// The report that ended the latest finished turn, while nothing reported
    /// since has taken it back, as working does.
    private(set) var ended: Mark?
    /// This device's seen mark: the finished turn it last looked at.
    private(set) var seen: Mark?
    /// Whether the program that made `last` has reported done.
    private(set) var hasReportedDone = false

    var isDone: Bool {
        guard let ended else { return false }
        return ended != seen
    }

    /// The root record while it is the terminal's Agent of `kind`'s own
    /// (`RexAgentRule.report(of:heldBy:)`).
    mutating func note(_ status: RexProgramStatus, kind: String) {
        let report = Report(state: status.state, mark: Mark(status), follow: status.follow)
        let previous = last
        last = report
        guard let previous, previous.mark.isSameProgram(as: report.mark) else {
            // First sight of this program: its done finished a turn, and
            // nothing says whether its idle did.
            hasReportedDone = report.state == "done"
            ended = report.state == "done" ? report.mark : nil
            return
        }
        // The record known here, read again.
        guard previous.state != report.state || previous.mark != report.mark else { return }
        if report.state == "done" { hasReportedDone = true }
        guard report.state == "idle" || report.state == "done" else {
            ended = nil
            return
        }
        let reportsDone = hasReportedDone || HerdrCoreTurnState.doneReporterKinds.contains(kind)
        let idleEndsTurn = previous.state == "working" && report.state == "idle" && !reportsDone
        let countEndsTurn =
            if let follow = report.follow, let before = previous.follow, follow.id == before.id {
                follow.finishedTurns > before.finishedTurns
            } else {
                report.state == "done"
            }
        // Rex drops a working record while its program is out of the
        // foreground, and one back in it may report done straight away.
        let doneEndsTurn = report.state == "done" && (previous.state == "working" || previous.state == "blocked")
        if countEndsTurn || doneEndsTurn || idleEndsTurn { ended = report.mark }
    }

    /// The terminal hosts no Agent now, or its record is not the Agent's: a
    /// later one starts with no Done, as on the other kinds.
    mutating func noteNoAgent() {
        ended = nil
    }

    /// This device looks at the Agent: the turn it finished is seen.
    mutating func markSeen() {
        if let ended { seen = ended }
    }
}
