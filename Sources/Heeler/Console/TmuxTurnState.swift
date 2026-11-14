import Foundation

/// What this device knows of one tmux Pane's turns, and so whether its Agent
/// reads Done here (ADR 0046): it finished a turn after this device's seen mark
/// and reads idle or done. The Pane's `turn` count already moves only when a
/// turn ends, so a later count is a finished turn, however many came between
/// two looks.
///
/// Marks keep ADR 0033's form, a count and a status word, and belong to one
/// server instance as a herdr-core Host's belong to one core.
/// `plugin/test-vectors/tmux-heeler-status-v1.json` holds this rule's cases.
struct TmuxTurnState: Codable, Equatable, Sendable {
    typealias Mark = HerdrCoreTurnState.Mark

    /// The last look at this Pane's Agent: the count and the word it reported,
    /// nil for none.
    private(set) var last: Mark?
    /// This device's seen mark.
    private(set) var seen: Mark?
    /// The Agent the last look found.
    private(set) var kind: String?
    /// The count when the Pane's last Agent left: its turns are not Done for
    /// the program that comes next.
    private(set) var departedTurn: Int?

    var isDone: Bool {
        guard let last, last.word == "idle" || last.word == "done" else { return false }
        return last.turn > max(seen?.turn ?? 0, departedTurn ?? 0)
    }

    /// One look at the option while the Pane hosts an Agent of `kind`. With the
    /// Agent open on this device, a finished turn is seen as it shows.
    mutating func noteSample(_ status: TmuxProgramStatus, kind: String, isShown: Bool) {
        if let previous = self.kind, previous != kind, let last { departedTurn = last.turn }
        self.kind = kind
        let mark = Mark(turn: status.turn, word: status.word(forAgent: kind))
        last = mark
        if isShown, seen.map({ mark.turn > $0.turn }) ?? true { seen = mark }
    }

    /// A look that found no Agent in the Pane.
    mutating func noteNoAgent(_ status: TmuxProgramStatus) {
        departedTurn = status.turn
        kind = nil
        last = nil
    }

    /// This device opened the Agent: the mark is where it stands.
    mutating func markSeen() {
        if let last { seen = last }
    }

    /// The Agent Status the Console shows after the last look, Done included.
    var agentStatus: AgentStatus {
        switch last?.word {
        case "idle", "done": isDone ? .done : .idle
        case "working": .working
        case "blocked": .blocked
        case "error": .error
        default: .unknown
        }
    }
}
