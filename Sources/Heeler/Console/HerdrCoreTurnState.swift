/// What this device knows of one Terminal's turns, and so whether its Agent reads
/// Done here (ADR 0033): it finished a turn after this device's seen mark and
/// still reports idle or done. A turn's end comes from the status word. The turn
/// count cannot tell it: the count also moves on entering Blocked or Error and on
/// Codex's start-up blip, and a move from Blocked straight to Done leaves it alone.
///
/// `plugin/test-vectors/herdr-core-turn-end-v1.json` holds this rule's cases, so a
/// change here changes that file and the Helper's reading of it in one commit.
struct HerdrCoreTurnState: Codable, Equatable, Sendable {
    /// A point in a Terminal's reports. The word tells two points at one count
    /// apart: an Agent opened while Blocked has not seen the Done that follows.
    struct Mark: Codable, Equatable, Sendable {
        var turn: Int
        var word: String?
    }

    /// Agent kinds known to report done, whose idle therefore ends no turn.
    static let doneReporterKinds: Set<String> = ["claude", "codex", "pi", "omp"]

    /// The last report this device knows of.
    private(set) var last: Mark?
    /// The latest finished turn, while the Agent has not reported anything since
    /// that takes it back, as working does.
    private(set) var ended: Mark?
    /// This device's seen mark.
    private(set) var seen: Mark?
    /// Whether this Terminal has reported done since its last restart.
    private(set) var hasReportedDone = false

    var isDone: Bool {
        guard let ended else { return false }
        return ended != seen
    }

    // MARK: Events

    /// One `status` event, whose `turn` is the count on the record. The core
    /// moves the count before it sends the event, and says so only in the `turn`
    /// event after it, so the count of a report that left working is worked out
    /// here: a mark made in between has to match what a later snapshot says.
    @discardableResult
    mutating func noteStatus(word: String?, turn: Int, kind: String?) -> Bool {
        let previous = last?.word
        guard previous != word || last == nil else { return false }
        let leftWorking = previous == "working" && word != "working"
        let mark = Mark(turn: leftWorking ? turn + 1 : turn, word: word)
        last = mark
        let reportsDone = reportsDone(kind)
        if word == "done" { hasReportedDone = true }
        guard Self.endsTurn(from: previous, to: word, reportsDone: reportsDone) else {
            if !Self.keepsAFinishedTurn(word) { ended = nil }
            return false
        }
        ended = mark
        return true
    }

    /// One `turn` event: the count the core moved.
    mutating func noteTurn(_ turn: Int) {
        guard var mark = last, mark.turn != turn else { return }
        if ended == mark { ended?.turn = turn }
        mark.turn = turn
        last = mark
    }

    /// A kept restart: the turn count carries over and the reports do not.
    mutating func noteRestart(turn: Int) {
        last = Mark(turn: turn, word: nil)
        ended = nil
        hasReportedDone = false
    }

    /// A snapshot stands in for whatever happened since the last report known
    /// here, and event numbers cannot be resumed to ask. Only leaving working
    /// moves the count, so the same count means no working came between. A moved
    /// or new one means some turn stopped working, and what the word says now is
    /// all that is left to tell how.
    @discardableResult
    mutating func noteSnapshot(turn: Int, word: String?, kind: String?, reported: Bool) -> Bool {
        // Only a kept restart clears `reported`.
        if !reported { hasReportedDone = false }
        let previous = last
        let mark = Mark(turn: turn, word: word)
        last = mark
        let reportsDone = reportsDone(kind)
        if word == "done" { hasReportedDone = true }
        guard previous != mark else { return false }
        guard Self.keepsAFinishedTurn(word) else {
            ended = nil
            return false
        }
        let endsTurn: Bool
        if let previous, previous.turn == turn {
            endsTurn = Self.endsTurn(from: previous.word, to: word, reportsDone: reportsDone)
        } else {
            ended = nil
            endsTurn = turn > 0 && (word == "done" || !reportsDone)
        }
        if endsTurn { ended = mark }
        return endsTurn
    }

    /// The Agent rule finds no Agent here now: a later one starts with no Done,
    /// whatever report the core kept.
    mutating func noteNoAgent() {
        ended = nil
    }

    // MARK: Seen marks

    /// This device opened the Agent. The mark is the turn that ended, which any
    /// key may since have turned from done into idle, else where it stands.
    mutating func markSeen() {
        seen = ended ?? last ?? seen
    }

    /// This device has the Agent open: a turn that just ended is seen, and with
    /// none it leaves the mark from opening it.
    mutating func markEndedTurnSeen() {
        if let ended { seen = ended }
    }

    // MARK: The rule

    private func reportsDone(_ kind: String?) -> Bool {
        hasReportedDone || kind.map(Self.doneReporterKinds.contains) == true
    }

    /// A move from Blocked straight to Done ends the turn that went to Blocked.
    private static func endsTurn(from previous: String?, to word: String?, reportsDone: Bool) -> Bool {
        switch (previous, word) {
        case ("working", "done"), ("blocked", "done"): true
        case ("working", "idle"): !reportsDone
        default: false
        }
    }

    private static func keepsAFinishedTurn(_ word: String?) -> Bool {
        word == "idle" || word == "done"
    }
}
