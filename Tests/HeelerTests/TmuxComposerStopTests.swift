import Foundation
import Testing

@testable import Heeler

/// Composer Stop on a tmux Host (ADRs 0024, 0043 and 0044), from
/// `ConsoleStore.terminalInterrupt` through the Attach's control client and
/// Heeler's own compare-and-set of `@heeler-status`.
@MainActor
@Suite("tmux Composer Stop", .timeLimit(.minutes(1)))
struct TmuxComposerStopTests {
    @MainActor
    private struct Fixture {
        let tmux: ScriptedTmuxHost
        let console: ConsoleStore
        let host: Host
        let clock = ManualClock()
        let attach: AgentAttachStore
        let corePin: TerminalCorePin
        let agent: ConsoleAgent

        init(
            command: String,
            app: String,
            state: String = "working",
            turn: Int = 2,
            blocked: Int = 1,
            height: Int = 24,
            width: Int = 80
        ) async throws {
            let status = "state=\(state):app=\(app):turn=\(turn):blocked=\(blocked)"
            let tmux = ScriptedTmuxHost()
            let pane = TmuxInventory.Pane.make(
                pane: 0, processID: 4000, command: command, width: width, height: height,
                status: status, arguments: [command])
            await tmux.setPanes([pane])
            self.tmux = tmux
            let host = Host(
                address: "mac.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())
            self.host = host
            let clock = clock
            let console = ConsoleStore(
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeTmuxSession: { host in
                    TmuxHostSession(
                        storedPaths: host.storedTmuxPaths,
                        connect: { paths in
                            await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths)
                        },
                        reconnectPolicy: ReconnectPolicy(
                            initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
                        keepalive: nil)
                },
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "tmux-stop-\(UUID().uuidString)") ?? .standard),
                coreSendClock: BlockedCardClock(now: clock.clock.now, sleep: clock.parkedSleep(for:)))
            self.console = console
            console.setHosts([host])
            await console.resume()
            try await Self.waitUntil("the Agent") { [console] in !console.agents.isEmpty }
            let agent = try #require(console.agents.first)
            self.agent = agent
            let session = console.composerSession(for: agent)
            corePin = session.corePin
            attach = AgentAttachStore(
                target: agent.agent.paneID, paneTitle: "", transportGeneration: nil, isOnStage: { true },
                runTerminal: console.terminalRunner(for: host.id, keepingTo: session.corePin), closePane: {})
        }

        func live(columns: Int = 80, rows: Int = 24) async throws {
            attach.viewDidResize(cols: columns, rows: rows)
            try await Self.waitUntil("the Attach's first paint") { [attach] in
                attach.input.readySession != nil
            }
        }

        func show(_ stem: String) async throws {
            var lines = try ScreenFixture.text(stem)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if lines.last?.isEmpty == true { lines.removeLast() }
            await tmux.setScreen(lines, of: "%0")
        }

        func interrupt() -> AgentComposerInterrupt? {
            console.terminalInterrupt(for: agent, keepingTo: corePin, attach: attach) { .sent }
        }

        func stopCommands(after mark: Int) async -> [[String]] {
            let lines = await tmux.controlCommands
            return lines.dropFirst(mark).flatMap(ScriptedTmuxHost.commandList(of:)).filter { words in
                words.first == "capture-pane" || words.first == "send-keys"
            }
        }

        func finish() async {
            await attach.leave().value
            console.setHosts([])
        }

        static func waitUntil(
            _ what: String, _ condition: @MainActor () async -> Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            for _ in 0..<500 {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }
    }

    private static let escape = ["send-keys", "-t", "%0", "Escape"]
    private static let notSent = "The terminal isn't connected, so Stop wasn't sent."

    @Test(arguments: [
        ("claude", "claude-code"),
        ("codex", "codex"),
        ("pi", "pi"),
        ("omp", "omp"),
    ])
    func oneEscapeWritesIdleWithoutReadingTheScreen(command: String, app: String) async throws {
        let fixture = try await Fixture(command: command, app: app)
        try await fixture.live()
        let mark = await fixture.tmux.controlCommands.count
        let ask = "kept-by-the-hook"
        await fixture.tmux.setAsk(ask, of: "%0")

        let interrupt = try #require(fixture.interrupt())
        let outcome = await interrupt.perform()

        #expect(outcome == .sent)
        #expect(await fixture.stopCommands(after: mark) == [Self.escape])
        #expect(await fixture.tmux.status(of: "%0") == "state=idle:app=\(app):turn=2:blocked=1")
        // Only a Claude Code idle write clears the hook's question.
        let kept = app == "claude-code" ? "" : ask
        #expect(await fixture.tmux.ask(of: "%0") == kept)
        await fixture.finish()
    }

    @Test func stopStaysOfferedWhileTheAgentIsBlocked() async throws {
        let fixture = try await Fixture(command: "claude", app: "claude-code")
        let composer = fixture.console.composerSession(for: fixture.agent).composer
        #expect(composer.offersStopWhileBlocked)
        #expect(
            AgentComposerPrimaryControl(
                status: .blocked, draft: "", canStop: true, alsoWhileBlocked: composer.offersStopWhileBlocked)
                == .stop)
        #expect(
            AgentComposerPrimaryControl(
                status: .idle, draft: "", canStop: true, alsoWhileBlocked: composer.offersStopWhileBlocked)
                == .send)

        let gate = ScriptedTransportCallGate()
        let wait = composer.stop.stop {
            await gate.waitUntilOpen()
            return .sent
        }
        await gate.waitForEntry()
        composer.agentStatusDidChange(.blocked)
        #expect(composer.stop.isStopping)
        composer.agentStatusDidChange(.idle)
        #expect(composer.stop.phase == .ready)
        await gate.open()
        await wait?.value
        #expect(composer.stop.phase == .ready)
        await fixture.finish()
    }

    @Test func aBlockedClaudeCodeStopStillSendsEscapeAndWritesIdle() async throws {
        let fixture = try await Fixture(command: "claude", app: "claude-code", state: "blocked", turn: 1, blocked: 2)
        try await fixture.live()
        #expect(fixture.agent.agent.status == .blocked)
        let mark = await fixture.tmux.controlCommands.count

        let outcome = await fixture.interrupt()?.perform()

        #expect(outcome == .sent)
        #expect(await fixture.stopCommands(after: mark) == [Self.escape])
        #expect(await fixture.tmux.status(of: "%0") == "state=idle:app=claude-code:turn=1:blocked=2")
        await fixture.finish()
    }

    @Test func openCodeSendsTwoEscapesAfterTheScreenAllowsAndAdvancesTheTurn() async throws {
        let fixture = try await Fixture(command: "opencode", app: "opencode", turn: 0, blocked: 0, height: 41)
        try await fixture.show("opencode-35-working-62")
        try await fixture.live(rows: 41)
        await fixture.tmux.setAsk("kept", of: "%0")
        let mark = await fixture.tmux.controlCommands.count

        let outcome = await fixture.interrupt()?.perform()

        #expect(outcome == .sent)
        let commands = await fixture.stopCommands(after: mark)
        #expect(commands.first?.first == "capture-pane")
        #expect(commands.dropFirst().map { $0 } == [Self.escape, Self.escape])
        #expect(await fixture.tmux.status(of: "%0") == "state=idle:app=opencode:turn=1:blocked=0")
        #expect(await fixture.tmux.ask(of: "%0") == "kept")
        await fixture.finish()
    }

    @Test func openCodePressesNothingWhileBlocked() async throws {
        let fixture = try await Fixture(
            command: "opencode", app: "opencode", state: "blocked", turn: 3, blocked: 1, height: 41)
        try await fixture.show("opencode-35-working-62")
        try await fixture.live(rows: 41)
        let before = await fixture.tmux.status(of: "%0")
        let mark = await fixture.tmux.controlCommands.count

        let outcome = await fixture.interrupt()?.perform()

        #expect(outcome == .failed("The turn already ended, so Stop pressed nothing."))
        let commands = await fixture.stopCommands(after: mark)
        #expect(commands.map(\.first) == ["capture-pane"])
        #expect(await fixture.tmux.status(of: "%0") == before)
        await fixture.finish()
    }

    @Test func grokPressesCtrlCOnceTheScreenAllows() async throws {
        let fixture = try await Fixture(command: "grok", app: "grok-build", turn: 0, blocked: 0, height: 20)
        try await fixture.show("grok-32-working-62x20")
        try await fixture.live(rows: 20)
        let mark = await fixture.tmux.controlCommands.count

        let outcome = await fixture.interrupt()?.perform()

        #expect(outcome == .sent)
        let commands = await fixture.stopCommands(after: mark)
        #expect(commands.first?.first == "capture-pane")
        #expect(commands.last == ["send-keys", "-t", "%0", "C-c"])
        #expect(commands.filter { $0.first == "send-keys" }.count == 1)
        #expect(await fixture.tmux.status(of: "%0") == "state=idle:app=grok-build:turn=0:blocked=0")
        await fixture.finish()
    }

    @Test func grokPressesNothingWhileBlockedOrOnABlankScreen() async throws {
        let blocked = try await Fixture(command: "grok", app: "grok-build", state: "blocked")
        try await blocked.live()
        let blockedBefore = await blocked.tmux.status(of: "%0")
        let blockedMark = await blocked.tmux.controlCommands.count
        let blockedOutcome = await blocked.interrupt()?.perform()
        #expect(blockedOutcome == .failed(
            "Grok Build is asking something, so Stop pressed nothing. Answer it in Chat or the terminal."))
        #expect(await blocked.stopCommands(after: blockedMark).map(\.first) == ["capture-pane"])
        #expect(await blocked.tmux.status(of: "%0") == blockedBefore)
        await blocked.finish()

        let blank = try await Fixture(command: "grok", app: "grok-build")
        try await blank.live()
        let blankBefore = await blank.tmux.status(of: "%0")
        let blankMark = await blank.tmux.controlCommands.count
        let blankOutcome = await blank.interrupt()?.perform()
        #expect(blankOutcome == .failed(
            "Grok Build is showing a menu or another view, so Stop pressed nothing. Close it in the terminal first."))
        #expect(await blank.stopCommands(after: blankMark).map(\.first) == ["capture-pane"])
        #expect(await blank.tmux.status(of: "%0") == blankBefore)
        await blank.finish()
    }

    @Test func aKeyThatDoesNotLeaveWritesNothing() async throws {
        let fixture = try await Fixture(command: "codex", app: "codex")
        try await fixture.live()
        await fixture.tmux.failNextSendKeys()
        let before = await fixture.tmux.status(of: "%0")

        let outcome = await fixture.interrupt()?.perform()

        #expect(outcome == .failed(Self.notSent))
        #expect(await fixture.tmux.status(of: "%0") == before)
        await fixture.finish()
    }

    @Test func theSecondOpenCodeEscapeFailingWritesNothing() async throws {
        let fixture = try await Fixture(command: "opencode", app: "opencode", height: 41)
        try await fixture.show("opencode-35-working-62")
        try await fixture.live(rows: 41)
        await fixture.tmux.failSendKeys(1, after: 1)
        let before = await fixture.tmux.status(of: "%0")
        let mark = await fixture.tmux.controlCommands.count

        let outcome = await fixture.interrupt()?.perform()

        #expect(outcome == .failed(ChatStopPlan.unreachableMessage))
        let commands = await fixture.stopCommands(after: mark)
        #expect(commands.first?.first == "capture-pane")
        // The refused key is still a command the control client sent.
        // The outcome and the unchanged status say it did not leave.
        #expect(Array(commands.dropFirst()) == [Self.escape, Self.escape])
        #expect(await fixture.tmux.status(of: "%0") == before)
        await fixture.finish()
    }

    @Test func aMissingAttachWritesNothing() async throws {
        let fixture = try await Fixture(command: "claude", app: "claude-code")
        let before = await fixture.tmux.status(of: "%0")
        let interrupt = fixture.console.terminalInterrupt(
            for: fixture.agent, keepingTo: fixture.corePin, attach: nil
        ) { .sent }

        let outcome = await interrupt?.perform()

        #expect(outcome == .failed(Self.notSent))
        #expect(await fixture.tmux.status(of: "%0") == before)
        await fixture.finish()
    }

    @Test func anUnreadableScreenWritesNothing() async throws {
        let fixture = try await Fixture(command: "grok", app: "grok-build")
        try await fixture.live()
        await fixture.tmux.failNextCapture()
        let before = await fixture.tmux.status(of: "%0")
        let mark = await fixture.tmux.controlCommands.count

        let outcome = await fixture.interrupt()?.perform()

        #expect(outcome == .failed(ChatStopPlan.unreadableScreenMessage))
        #expect(await fixture.stopCommands(after: mark).map(\.first) == ["capture-pane"])
        #expect(await fixture.tmux.status(of: "%0") == before)
        await fixture.finish()
    }

    @Test func typedTextLeavesBeforeStop() async throws {
        let fixture = try await Fixture(command: "pi", app: "pi")
        try await fixture.live()
        let mark = await fixture.tmux.controlCommands.count
        #expect(fixture.attach.input.send(Data("ab".utf8)))

        let outcome = await fixture.interrupt()?.perform()

        #expect(outcome == .sent)
        let commands = await fixture.stopCommands(after: mark)
        let typed = commands.firstIndex { $0 == ["send-keys", "-l", "-t", "%0", "--", "ab"] }
        let escape = commands.firstIndex { $0 == Self.escape }
        let typedAt = try #require(typed)
        let escapeAt = try #require(escape)
        #expect(typedAt < escapeAt)
        await fixture.finish()
    }

    @Test func anUnlistedProgramKeepsSend() async throws {
        let fixture = try await Fixture(command: "cursor", app: "cursor", state: "working")
        #expect(fixture.console.capabilities(for: fixture.host.id).composerStop)
        #expect(fixture.agent.agent.kind == "cursor")
        #expect(fixture.interrupt() == nil)
        await fixture.finish()
    }

    @Test func toolsEscapeDeclinesOnlyABlockedClaudeCodeQuestion() {
        #expect(TmuxConsoleProjection.toolsEscapeDeclines(kind: "claude", status: .blocked))
        #expect(!TmuxConsoleProjection.toolsEscapeDeclines(kind: "claude", status: .working))
        #expect(!TmuxConsoleProjection.toolsEscapeDeclines(kind: "claude", status: .idle))
        #expect(!TmuxConsoleProjection.toolsEscapeDeclines(kind: "codex", status: .blocked))
        #expect(!TmuxConsoleProjection.toolsEscapeDeclines(kind: "opencode", status: .blocked))
        #expect(!TmuxConsoleProjection.toolsEscapeDeclines(kind: nil, status: .blocked))
    }

    @Test func aDecliningAnswerWritesIdleAndClearsAClaudeQuestion() async throws {
        let fixture = try await Fixture(
            command: "claude", app: "claude-code", state: "blocked", turn: 4, blocked: 2)
        await fixture.tmux.setAsk("UGljaw==", of: "%0")

        let outcome = await fixture.console.recordHeelerAnswer(declines: true, for: fixture.agent)

        #expect(outcome == .applied("state=idle:app=claude-code:turn=4:blocked=2"))
        #expect(await fixture.tmux.status(of: "%0") == "state=idle:app=claude-code:turn=4:blocked=2")
        #expect(await fixture.tmux.ask(of: "%0") == "")
        await fixture.finish()
    }

    @Test func anyOtherAnswerWritesWorking() async throws {
        let claude = try await Fixture(
            command: "claude", app: "claude-code", state: "blocked", turn: 4, blocked: 2)
        await claude.tmux.setAsk("UGljaw==", of: "%0")
        let claudeOutcome = await claude.console.recordHeelerAnswer(declines: false, for: claude.agent)
        #expect(claudeOutcome == .applied("state=working:app=claude-code:turn=4:blocked=2"))
        #expect(await claude.tmux.ask(of: "%0") == "")
        await claude.finish()

        let open = try await Fixture(command: "opencode", app: "opencode", state: "blocked", turn: 3, blocked: 1)
        await open.tmux.setAsk("kept", of: "%0")
        let openOutcome = await open.console.recordHeelerAnswer(declines: true, for: open.agent)
        #expect(openOutcome == .applied("state=idle:app=opencode:turn=3:blocked=1"))
        #expect(await open.tmux.ask(of: "%0") == "kept")
        await open.finish()
    }

    @Test func anUnlistedProgramAnswerWritesNothing() async throws {
        let fixture = try await Fixture(command: "cursor", app: "cursor")
        let before = await fixture.tmux.status(of: "%0")
        let outcome = await fixture.console.recordHeelerAnswer(declines: false, for: fixture.agent)
        #expect(outcome == .failed)
        #expect(await fixture.tmux.status(of: "%0") == before)
        await fixture.finish()
    }

    @Test func anAcknowledgedEscapeLeavesBeforeADeclineWritesIdle() async throws {
        let fixture = try await Fixture(command: "claude", app: "claude-code", state: "blocked", turn: 1, blocked: 1)
        try await fixture.live()
        await fixture.tmux.setAsk("UGljaw==", of: "%0")
        let mark = await fixture.tmux.controlCommands.count

        #expect(await fixture.attach.sendEscapeKeyAcknowledged())
        #expect(await fixture.stopCommands(after: mark) == [Self.escape])
        let outcome = await fixture.console.recordHeelerAnswer(declines: true, for: fixture.agent)

        #expect(outcome == .applied("state=idle:app=claude-code:turn=1:blocked=1"))
        #expect(await fixture.tmux.ask(of: "%0") == "")
        await fixture.finish()
    }

    @Test func escapeWhileClaudeIsWorkingWritesNothing() async throws {
        let fixture = try await Fixture(command: "claude", app: "claude-code")
        try await fixture.live()
        let before = await fixture.tmux.status(of: "%0")
        let mark = await fixture.tmux.controlCommands.count

        #expect(await fixture.attach.sendEscapeKeyAcknowledged())

        #expect(await fixture.stopCommands(after: mark) == [Self.escape])
        #expect(await fixture.tmux.status(of: "%0") == before)
        await fixture.finish()
    }

    @Test func keysThatLeftStillCountWhenAnotherWriterWonTheStatus() async throws {
        let fixture = try await Fixture(command: "claude", app: "claude-code")
        try await fixture.live()
        let winner = "state=blocked:app=claude-code:kind=question:turn=9:blocked=4"
        await fixture.tmux.setStatusQuietly(winner, of: "%0")

        let outcome = await fixture.interrupt()?.perform()

        #expect(outcome == .sent)
        #expect(await fixture.tmux.status(of: "%0") == winner)
        await fixture.finish()
    }
}
