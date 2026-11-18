import Foundation
import Testing

@testable import Heeler

/// Explicit opt-in only: a lab terminal's Program Status reaching the inventory
/// a `RexHostSession` follows, the turns its link counts, and the Agent it
/// makes, Done included (ADR 0054), against a Rex
/// server that already runs on this Mac, over its local Unix socket. It never
/// runs in the HeelerTests target or in CI, and fails rather than skips when
/// selected without its configuration.
///
/// It creates one session labeled `heeler-lab-r7-…` with one shell under a
/// scrubbed environment and types into that shell only: an inert stand-in, a
/// shell started under the first argument `codex`, that reports the states it
/// reads and starts no agent. Heeler's session only reads, on its control
/// connection: it opens no data connection and attaches to no terminal. The
/// lab destroys its session at the end. It prints only states and counts,
/// never labels, titles or terminal text. `/tmp/heeler-lab-home` must exist.
///
/// ```sh
/// mkdir -p /tmp/heeler-lab-home
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SOCKET "<socket path>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/RexProgramStatusLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SOCKET
/// ```
@MainActor
@Suite("Rex program status over a local socket", .serialized, .timeLimit(.minutes(2)))
struct RexProgramStatusLiveTests {
    /// The stand-in: a shell named `codex` by its first argument, reporting
    /// `working` and then each line it reads as a state, until end of input.
    static let standIn =
        #"(exec -a codex /bin/sh -c 's=working; while :; do printf "\033]7501;state=%s:app=codex\007" "$s"; printf "ok\n"; read s || break; done')"#
        + "\r"

    @Test func aLabTerminalsReportReachesTheInventory() async throws {
        let socketPath = try #require(
            ProcessInfo.processInfo.environment["HEELER_REX_LIVE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 },
            "HEELER_REX_LIVE_SOCKET names no Rex socket")
        let lab = try await RexLab.open(path: socketPath)
        var failure: (any Error)?
        do {
            try await run(lab, socketPath: socketPath)
        } catch {
            failure = error
        }
        let remaining = await lab.destroyEverything()
        print("Rex lab: \(remaining.lab) lab sessions remain, \(remaining.total) sessions in all")
        #expect(remaining.lab == 0)
        await lab.control.close()
        if let failure { throw failure }
    }

    private func run(_ lab: RexLab, socketPath: String) async throws {
        let created = try await lab.createSession(
            blocks: [("agent", ["/bin/sh"])], grid: LocalGrid(columns: 100, rows: 30), name: "r7")
        let block = created.blocks[0]
        let type = { (text: String) in try await lab.type(text, session: created.id, block: block) }

        let session = RexHostSession(storedSocket: RexSocket(path: socketPath)) { _, previous in
            try await LocalRexTransport.connect(path: socketPath, resuming: previous)
        }
        let followed = Followed()
        await session.resume()
        let following = Task { @MainActor in
            for await update in session.updates {
                if case .inventory(let next) = update { followed.inventory = next }
            }
        }
        defer { following.cancel() }
        /// The lab terminal as the latest inventory has it, and its session
        /// alone as the Console would organize it.
        func labTerminal() -> (details: RexTerminalDetails, agents: [AgentInfo])? {
            guard let labSession = followed.inventory?.sessions.first(where: { $0.id == created.id }),
                let terminal = labSession.terminals.first(where: { $0.blockID == block })
            else { return nil }
            return (terminal.details, RexOrganization.build(RexInventory(sessions: [labSession])).agents)
        }
        func reads(_ status: AgentStatus) -> Bool {
            guard let terminal = labTerminal() else { return false }
            return RexAgentRule.agentKind(in: terminal.details) == "codex"
                && RexAgentRule.status(of: terminal.details, heldBy: "codex") == status
                && terminal.agents.map(\.agentStatus) == [status]
        }

        try await waitUntil("the lab shell in the inventory", timeout: .seconds(20)) {
            labTerminal()?.details.program != nil
        }
        let shell = try #require(labTerminal())
        print("Rex lab: the shell is an Agent: \(RexAgentRule.agentKind(in: shell.details) != nil)")
        #expect(RexAgentRule.agentKind(in: shell.details) == nil)
        #expect(shell.agents.isEmpty)

        try await type(Self.standIn)
        try await waitUntil("the stand-in working", timeout: .seconds(10)) { reads(.working) }
        let started = try #require(labTerminal())
        print(
            "Rex lab: the stand-in reads \(started.details.status?.state ?? "nothing"), "
                + "owned by the foreground: \(started.details.status?.ownerProcessID == started.details.processID)")

        try await type("blocked\r")
        try await waitUntil("the stand-in blocked", timeout: .seconds(10)) { reads(.blocked) }
        try await type("error\r")
        try await waitUntil("the stand-in in error", timeout: .seconds(10)) { reads(.error) }

        // The server refuses a word it does not know, so the last report stands.
        try await type("thinking\r")
        try await Task.sleep(for: .seconds(1))
        let refused = try #require(labTerminal())
        print("Rex lab: after an unknown word the record reads \(refused.details.status?.state ?? "nothing")")
        #expect(refused.details.status?.state == "error")

        // Working to done is a turn the link counts, and reads Done until this
        // device looks at it. The same done made again moves the record's
        // time, but the link counts no turn, so it stays seen.
        try await type("working\r")
        try await waitUntil("the stand-in working again", timeout: .seconds(10)) { reads(.working) }
        let working = try #require(labTerminal()?.details.status)
        var turns = RexTurnState()
        turns.note(working, kind: "codex")
        try await type("done\r")
        try await waitUntil("the stand-in done", timeout: .seconds(10)) {
            reads(.idle) && labTerminal()?.details.status?.state == "done"
        }
        let done = try #require(labTerminal()?.details.status)
        turns.note(done, kind: "codex")
        print(
            "Rex lab: done moved the link's count by "
                + "\((done.follow?.finishedTurns ?? 0) - (working.follow?.finishedTurns ?? 0)), "
                + "in the same stretch: \(done.follow?.id == working.follow?.id), reads Done: \(turns.isDone)")
        #expect(done.follow?.id == working.follow?.id)
        #expect(done.follow?.finishedTurns == (working.follow?.finishedTurns ?? 0) + 1)
        #expect(turns.isDone)
        turns.markSeen()
        try await type("done\r")
        try await waitUntil("the same done again", timeout: .seconds(10)) {
            labTerminal()?.details.status.map { $0.state == "done" && $0.updatedAt != done.updatedAt } == true
        }
        let again = try #require(labTerminal()?.details.status)
        turns.note(again, kind: "codex")
        print(
            "Rex lab: the same done again moved the time: \(again.updatedAt != done.updatedAt), "
                + "moved the count: \(again.follow != done.follow), reads Done: \(turns.isDone)")
        #expect(again.follow == done.follow)
        #expect(!turns.isDone)

        // Idle, then the stand-in exits: the record stays, still naming the
        // stand-in, and the terminal is no Agent.
        try await type("idle\r")
        try await waitUntil("the stand-in idle", timeout: .seconds(10)) { reads(.idle) }
        try await type("\u{4}")
        try await type("echo back\r")
        try await waitUntil("the shell back", timeout: .seconds(10)) {
            labTerminal().map { RexAgentRule.agentKind(in: $0.details) == nil } == true
        }
        let left = try #require(labTerminal())
        let staleKept = left.details.status.map { $0.state == "idle" && $0.ownerProcessID != left.details.processID }
        print("Rex lab: after the stand-in left, a stale idle record kept: \(staleKept == true)")
        #expect(left.agents.isEmpty)

        await session.end()
    }

    @MainActor
    final class Followed {
        var inventory: RexInventory?
    }

    private func waitUntil(
        _ what: String, timeout: Duration, sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }
}
