import Foundation

/// Heeler's own write of a tmux Pane's `@heeler-status` (ADR 0046): the next
/// value continues the counts the Pane already holds, and it lands only while
/// that value is still there. A Claude Code write can clear `@heeler-ask` in
/// the same compare. One attempt, through the Host's own tmux socket.
enum TmuxStatusWrite {
    enum Outcome: Equatable, Sendable {
        /// The Pane now holds this value.
        case applied(String)
        /// The Pane held something else, which this write left as it was.
        case superseded(String)
        /// The command did not answer.
        case failed
    }

    /// Writes `report` over `current`. `clearAsk` clears `@heeler-ask` when
    /// the compare wins.
    static func apply(
        _ report: TmuxStatusReport,
        expecting current: String,
        pane: String,
        clearAsk: Bool,
        paths: TmuxPaths,
        run: @Sendable (TmuxLaunch.Command) async throws -> GitExecResult
    ) async -> Outcome {
        let next = TmuxProgramStatus.continued(current, by: report)
        let command = TmuxLaunch.compareAndSetStatus(
            pane: pane, expected: current, next: next, clearAsk: clearAsk, paths: paths)
        let result: GitExecResult
        do {
            result = try await run(command)
        } catch {
            return .failed
        }
        guard result.exitStatus == 0,
            let decoded = TmuxQuotedField.decodeLine(result.stdout, count: 1),
            let observed = decoded.first
        else { return .failed }
        return observed == next ? .applied(next) : .superseded(observed)
    }
}
