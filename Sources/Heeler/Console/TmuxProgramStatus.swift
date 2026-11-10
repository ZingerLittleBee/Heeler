import Foundation

/// A tmux Pane's Program Status as its `@heeler-status` option holds it
/// (ADR 0044): OSC 7501's words joined by `:`, then the Pane's two counts. Only
/// Heeler's integrations write it, and each continues the counts it found:
/// `turn` moves when a turn ends and `blocked` on each entry into blocked, so a
/// look every few seconds still sees two turns or two questions between looks.
///
/// `plugin/test-vectors/tmux-heeler-status-v1.json` holds the format and its
/// rules, read by the app, the hook script and the Helper alike.
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

    /// The word this status reports for an Agent of `kind`. A report whose `app`
    /// names another program Heeler knows is that program's, not this one's.
    func word(forAgent kind: String) -> String? {
        if let app, let reported = HerdrCoreAgentRule.reportedApps[app.lowercased()], reported != kind {
            return nil
        }
        return state
    }
}
