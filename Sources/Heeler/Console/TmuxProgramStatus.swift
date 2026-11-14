import Foundation

/// A tmux Pane's Program Status as its `@heeler-status` option holds it
/// (ADR 0046): OSC 7501's words joined by `:`, then the Pane's two counts. Only
/// Heeler's integrations write it, and each continues the counts it found:
/// `turn` moves when a turn ends and `blocked` on each entry into blocked, so a
/// look every few seconds still sees two turns or two questions between looks.
///
/// `plugin/test-vectors/tmux-heeler-status-v1.json` holds the format and its
/// rules, read by the app, the hook script and the Helper alike.
/// One report applied to a Pane's `@heeler-status` (`continueHeelerStatus`).
struct TmuxStatusReport: Equatable, Sendable {
    var state: String
    var app: String?
    var kind: String?
    /// Base64, as OSC 7501 carries it.
    var message: String?
}

struct TmuxProgramStatus: Equatable, Sendable {
    /// OSC 7501's `state`, nil for a status that was cleared or never set.
    var state: String?
    var app: String?
    var kind: String?
    /// Base64, as OSC 7501 carries it.
    var message: String?
    var turn = 0
    var blocked = 0

    /// A word it does not know is ignored, and a count that is missing or not
    /// a whole number reads 0.
    init(option: String) {
        for word in option.split(separator: ":") {
            guard let equals = word.firstIndex(of: "=") else { continue }
            let key = word[..<equals]
            let value = String(word[word.index(after: equals)...])
            switch key {
            case "state": state = value.isEmpty ? nil : value
            case "app": app = value.isEmpty ? nil : value
            case "kind": kind = value.isEmpty ? nil : value
            case "msg": message = value.isEmpty ? nil : value
            case "turn": turn = Self.count(value)
            case "blocked": blocked = Self.count(value)
            default: continue
            }
        }
    }

    private static func count(_ text: String) -> Int {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else { return 0 }
        return Int(text) ?? 0
    }

    /// Programs whose idle does not end a turn. These are the `app` words in
    /// `plugin/test-vectors/tmux-heeler-status-v1.json`, the same set the Helper
    /// continues counts with.
    static let doneReporterApps: Set<String> = ["claude-code", "codex", "pi", "omp", "grok-build"]

    /// The option value after `report`, continuing the counts in `previous`.
    /// An unset option is an empty value. `clear` keeps only the counts. A
    /// report from another program ends nothing of the one it found.
    static func continued(_ previous: String?, by report: TmuxStatusReport) -> String {
        let last = TmuxProgramStatus(option: previous ?? "")
        if report.state == "clear" {
            return "turn=\(last.turn):blocked=\(last.blocked)"
        }
        let app = report.app.flatMap { $0.isEmpty ? nil : $0 }
        let sameApp = last.state != nil && last.app == app
        let endsTurn = sameApp && (
            ((last.state == "working" || last.state == "blocked")
                && (report.state == "done" || report.state == "error"))
            || (last.state == "working" && report.state == "idle"
                && !doneReporterApps.contains(app ?? "")))
        let asks = report.state == "blocked" && !(sameApp && last.state == "blocked")
        var words = ["state=\(report.state)"]
        if let app { words.append("app=\(app)") }
        if let kind = report.kind, !kind.isEmpty { words.append("kind=\(kind)") }
        if let message = report.message, !message.isEmpty { words.append("msg=\(message)") }
        let turn = last.turn + (endsTurn ? 1 : 0)
        let blocked = last.blocked + (asks ? 1 : 0)
        return "\(words.joined(separator: ":")):turn=\(turn):blocked=\(blocked)"
    }

    /// The word this status reports for an Agent of `kind`. A report whose `app`
    /// names another program Heeler knows is that program's, not this one's.
    func word(forAgent kind: String) -> String? {
        if let app, let reported = HerdrCoreAgentRule.reportedApps[app.lowercased()], reported != kind {
            return nil
        }
        return state
    }
}
