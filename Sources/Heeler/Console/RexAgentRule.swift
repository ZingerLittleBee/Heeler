import Foundation

/// Which Rex terminal is an Agent, and its Agent Status (ADR 0054). A terminal
/// is one while a known agent program holds its foreground, read as
/// `HerdrCoreAgentRule` reads a herdr-core Terminal's and `TmuxAgentRule` a
/// tmux Pane's: Rex gives the foreground's name, its first argument and, for
/// an interpreter, its script, never its other arguments. A shell, any other
/// program and no foreground are terminals only, whatever they reported.
///
/// The status is the terminal's root Program Status while its owner, the
/// foreground when it was reported, is the foreground now by process id and
/// name: Rex keeps an exited program's idle, done and error records, and the
/// system reuses process ids. A report whose `app` names another known program
/// is that program's. Anything else reads Unknown. Done and idle both read
/// Idle here; whether this device has seen the turn a record finished, and so
/// whether it reads Done, is `RexTurnState`'s.
enum RexAgentRule {
    /// The kind of the Agent this terminal hosts, if it hosts one.
    static func agentKind(in details: RexTerminalDetails) -> String? {
        guard let name = details.program else { return nil }
        let arguments = [details.argv0 ?? name] + (details.script.map { [$0] } ?? [])
        guard case .known(let kind) = HerdrCoreAgentRule.program(arguments: arguments, name: name) else {
            return nil
        }
        return kind
    }

    /// The status of the Agent of `kind` this terminal hosts.
    static func status(of details: RexTerminalDetails, heldBy kind: String) -> AgentStatus {
        report(of: details, heldBy: kind).map { HerdrCoreAgentRule.agentStatus($0.state) } ?? .unknown
    }

    /// The root record, while it is the Agent of `kind`'s own.
    static func report(of details: RexTerminalDetails, heldBy kind: String) -> RexProgramStatus? {
        guard let report = details.status, let owner = report.ownerProcessID,
            owner == details.processID, report.ownerName == details.program
        else { return nil }
        let app = report.app?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let reported = HerdrCoreAgentRule.reportedApps[app], reported != kind { return nil }
        return report
    }
}
