import Foundation

/// Which tmux Pane is an Agent (ADR 0045). A Pane is one while a known agent
/// program holds its foreground, read as `HerdrCoreAgentRule` reads a
/// herdr-core Terminal's: past launch wrappers, `sh -c` lines, interpreters
/// and `npx`. A shell in the foreground ends it, a dead Pane hosts none, and
/// any other program is a terminal only, whatever its `@heeler-status` says:
/// on tmux every Program Status comes from Heeler's integrations for known
/// programs (ADR 0046).
///
/// The foreground is the process leading the Pane's foreground process group.
/// Its arguments come from the inventory loop, and where the Host could not
/// read them, tmux's own name for it stands in.
enum TmuxAgentRule {
    /// The kind of the Agent this Pane hosts, if it hosts one.
    static func agentKind(in pane: TmuxInventory.Pane) -> String? {
        guard !pane.isDead else { return nil }
        let program = HerdrCoreAgentRule.program(arguments: pane.foregroundArguments ?? [], name: pane.command)
        guard case .known(let kind) = program else { return nil }
        return kind
    }
}
