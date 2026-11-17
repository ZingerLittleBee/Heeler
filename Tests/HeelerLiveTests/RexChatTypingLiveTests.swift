import Foundation
import Testing

@testable import Heeler

/// Explicit opt-in only: Chat's reads and typing in a Rex terminal and
/// Composer Send (ADR 0055), through a `RexConsoleProjection` on its own
/// control connection, against a Rex server that already runs on this Mac,
/// over its local Unix socket. It never runs in the HeelerTests target or in
/// CI, and fails rather than skips when selected without its configuration.
///
/// It creates one session labeled `heeler-lab-r9-…` with one shell under a
/// scrubbed environment, which the lab's own client owns, and starts in it an
/// inert stand-in: a shell started under the first argument `codex` that turns
/// bracketed paste on, reports itself idle, and prints back with `cat -v`
/// whatever reaches it. It starts no agent. Heeler reads that terminal's screen
/// and types into it on the control connection only, then the test checks
/// that each input arrived once and in order and that the block's size and
/// owner did not move. It types into no other terminal, and the lab destroys
/// its session at the end. It prints only counts and booleans, never labels,
/// titles or terminal text. `/tmp/heeler-lab-home` must exist.
///
/// ```sh
/// mkdir -p /tmp/heeler-lab-home
/// xcrun simctl spawn <UDID> launchctl setenv HEELER_REX_LIVE_SOCKET "<socket path>"
/// make test-app SCHEME=HeelerLiveTests \
///   SIM_DESTINATION='platform=iOS Simulator,id=<UDID>' \
///   TEST_SELECTOR='HeelerLiveTests/RexChatTypingLiveTests'
/// xcrun simctl spawn <UDID> launchctl unsetenv HEELER_REX_LIVE_SOCKET
/// ```
@MainActor
@Suite("Rex chat typing over a local socket", .serialized, .timeLimit(.minutes(2)))
struct RexChatTypingLiveTests {
    /// The stand-in: a shell named `codex` by its first argument that echoes
    /// nothing itself, turns bracketed paste on, reports idle and prints each
    /// line it reads with `cat -v`. The trailing `:` keeps the shell, not
    /// `cat`, at the head of the foreground.
    static let standIn =
        #"(exec -a codex /bin/sh -c 'stty -echo; printf "\033[?2004h\033]7501;state=idle:app=codex\007"; printf "ready\n"; cat -v; :')"#
        + "\r"

    @Test func chatTypesIntoALabAgentAndTakesNothing() async throws {
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
        let grid = LocalGrid(columns: 100, rows: 30)
        let created = try await lab.createSession(blocks: [("agent", ["/bin/sh"])], grid: grid, name: "r9")
        let address = RexPaneAddress(sessionID: created.id, blockID: created.blocks[0])
        let paneID = address.paneID
        let size = {
            try await lab.control.call(
                RexInventoryWire.terminalMethod("size"),
                payload: JSONValue.object([
                    "session_id": .string(address.sessionID), "block_id": .string(address.blockID),
                ])
            ).result(JSONValue.self)
        }
        let lines = {
            try await lab.text(session: address.sessionID, block: address.blockID, unwrap: true)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }

        try await Task.sleep(for: .milliseconds(500))
        try await lab.type(Self.standIn, session: address.sessionID, block: address.blockID)
        try await waitUntil("the stand-in ready", timeout: .seconds(10)) {
            ((try? await lines()) ?? []).contains("ready")
        }

        let session = RexHostSession(storedSocket: RexSocket(path: socketPath)) { _, previous in
            try await LocalRexTransport.connect(path: socketPath, resuming: previous)
        }
        let host = Host(
            name: "Rex", address: "localhost", username: "lab", serverKind: .rex,
            rexSocket: RexSocket(path: socketPath))
        let projection = RexConsoleProjection(host: host, session: session, pins: PinnedAgentsStore(), onChange: {})
        projection.start(isActive: true)
        defer { projection.end() }
        try await waitUntil("the stand-in listed idle", timeout: .seconds(20)) {
            projection.agentsByPane[paneID]?.agent.status == .idle
        }
        let before = try await size()
        print("Rex lab: the lab's client owns the block: \(before["owner"].map { $0 != .null } == true)")

        // The screen, read on the control connection.
        let screen = try await projection.readAgentScreen(paneID)
        let shows: @Sendable (ANSIScreen) -> Bool = { $0.rows.contains { $0.text == "ready" } }
        print("Rex lab: the screen read has \(screen.rows.count) rows, shows the stand-in: \(shows(screen))")
        #expect(screen.rows.count == grid.rows)
        #expect(shows(screen))

        // Keys, a paste, a paste of two lines, Composer Send, and a Blocked
        // Card's answer over the screen it read.
        try await projection.sendAgentKeys(["esc", "enter"], to: paneID)
        try await projection.pasteIntoAgent("chat-one", paneID: paneID)
        try await projection.sendAgentKeys(["enter"], to: paneID)
        try await projection.pasteIntoAgent("chat-two-a\nchat-two-b", paneID: paneID)
        try await projection.sendAgentKeys(["enter"], to: paneID)
        let checked = projection.checkedComposerSend(
            for: paneID, keepingTo: TerminalCorePin(joined: projection.inventoryCore), live: { projection })
        let send = try #require(checked)
        let outcome = await send.send("composer-line", route: .chat, attach: nil)
        print("Rex lab: Composer Send submitted: \(outcome == .submitted)")
        #expect(outcome == .submitted)
        let blocked = try projection.chatTyping(at: paneID).blockedScreen
        _ = try await blocked.readScreen()
        try await blocked.type(.keys(["q", "7", "enter"]), whileShowing: shows)

        let expected = [
            "ready", "^[", "^[[200~chat-one^[[201~", "^[[200~chat-two-a", "chat-two-b^[[201~",
            "^[[200~composer-line^[[201~", "q7",
        ]
        try await waitUntil("the last answer", timeout: .seconds(10)) {
            ((try? await lines()) ?? []).contains("q7")
        }
        let printed = try await lines()
        let shown = printed.firstIndex(of: "ready").map { Array(printed[$0...].prefix(expected.count)) } ?? []
        print("Rex lab: each input arrived once and in order: \(shown == expected)")
        #expect(shown == expected)
        for line in expected {
            #expect(printed.count(where: { $0 == line }) == 1)
        }

        let after = try await size()
        let sameGrid = before["columns"] == after["columns"] && before["rows"] == after["rows"]
        print(
            "Rex lab: after Chat typed, the grid is the same: \(sameGrid), the owner is the same: "
                + "\(before["owner"] == after["owner"]), the whole size answer is the same: \(before == after)")
        #expect(sameGrid)
        #expect(before["owner"] == after["owner"])
        #expect(before == after)
        #expect(projection.agentsByPane[paneID]?.agent.status == .idle)

        _ = await lab.destroyEverything()
        await session.end()
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
