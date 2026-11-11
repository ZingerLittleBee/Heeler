import Foundation
import Testing

@testable import Heeler

/// Composer Send on a tmux Host (ADRs 0035 and 0043), from `AgentComposerStore`
/// down through `ConsoleStore`, `TmuxConsoleProjection`, `AgentAttachStore` and
/// `TmuxSSHTransport` over `ScriptedTmuxHost`, with time on `ManualClock`.
@MainActor
@Suite("tmux Composer Send", .timeLimit(.minutes(1)))
struct TmuxComposerSendTests {
    private static let escape = "\u{1B}"

    @MainActor
    private struct Fixture {
        let tmux: ScriptedTmuxHost
        let console: ConsoleStore
        let host = Host(
            address: "mac.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())
        let clock = ManualClock()
        let composer: AgentComposerStore
        let attach: AgentAttachStore
        let corePin: TerminalCorePin

        init(
            version: String = "tmux 3.7b",
            pane: TmuxInventory.Pane = .make(
                pane: 0, processID: 4000, command: "claude", status: "state=idle:app=claude-code:turn=0:blocked=0",
                arguments: ["claude"]),
            bracketedPaste: Bool = true
        ) async throws {
            let tmux = ScriptedTmuxHost(version: version)
            await tmux.setPanes([pane])
            await tmux.setBracketedPaste(bracketedPaste, of: pane.paneID)
            self.tmux = tmux
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
                    defaults: UserDefaults(suiteName: "tmux-send-\(UUID().uuidString)") ?? .standard),
                coreSendClock: BlockedCardClock(now: clock.clock.now, sleep: clock.parkedSleep(for:)))
            self.console = console
            console.setHosts([host])
            await console.resume()
            try await Self.waitUntil("the Agent") { [console] in !console.agents.isEmpty }
            let agent = try #require(console.agents.first)
            let session = console.composerSession(for: agent)
            composer = session.composer
            corePin = session.corePin
            composer.open()
            attach = AgentAttachStore(
                target: agent.agent.paneID, paneTitle: "", transportGeneration: nil, isOnStage: { true },
                runTerminal: console.terminalRunner(for: host.id, keepingTo: session.corePin), closePane: {})
        }

        var policy: ComposerDeliveryPolicy {
            var policy = ComposerDeliveryPolicy.terminal
            policy.coreAttach = attach
            return policy
        }

        func live() async throws {
            attach.viewDidResize(cols: 80, rows: 24)
            try await Self.waitUntil("the Attach's first paint") { [attach] in
                attach.input.readySession != nil
            }
        }

        func openOtherWindow() async throws -> AgentAttachStore {
            let other = AgentAttachStore(
                target: "%0", paneTitle: "", transportGeneration: nil, isOnStage: { true },
                runTerminal: console.terminalRunner(for: host.id, keepingTo: corePin), closePane: {})
            other.viewDidResize(cols: 80, rows: 24)
            try await Self.waitUntil("the second window's first paint") {
                other.input.readySession != nil
            }
            return other
        }

        func controlWords() async -> [[String]] {
            await tmux.controlCommands.flatMap(ScriptedTmuxHost.commandList(of:))
        }

        func sendWords() async -> [[String]] {
            await controlWords().filter { words in
                guard let first = words.first else { return false }
                return ["set-buffer", "paste-buffer", "delete-buffer", "send-keys"].contains(first)
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

    // MARK: Checked delivery

    @Test func sendsThroughNamedBufferChecksForegroundTwiceAndPressesEnter() async throws {
        let fixture = try await Fixture()
        try await fixture.live()
        await fixture.tmux.clearLog()

        let text = "line 1\r\nline 2\n中文 $HOME #{pane_id} ; 'q' \"dq\" \\"
        fixture.composer.replaceDraft(with: text)
        let result = await fixture.composer.send(policy: fixture.policy)

        #expect(result == .submittedViaAttach)
        #expect(fixture.composer.draft.isEmpty)
        #expect(fixture.composer.notice == nil)
        #expect(fixture.composer.messages.count == 1)
        #expect(fixture.composer.messages.first?.state == .delivered(.acknowledged))
        #expect(fixture.attach.input.userMessageIndex.entries.map(\.rawText) == [text])

        let words = await fixture.sendWords()
        #expect(words.count == 3)
        let setBuffer = try #require(words.first)
        #expect(setBuffer.prefix(2) == ["set-buffer", "-b"])
        let bufferName = try #require(setBuffer.dropFirst(2).first)
        #expect(bufferName.hasPrefix("heeler-attach-"))
        #expect(setBuffer == ["set-buffer", "-b", bufferName, "--", text])
        #expect(words[1] == ["paste-buffer", "-p", "-r", "-d", "-b", bufferName, "-t", "%0"])
        #expect(words[2] == ["send-keys", "-t", "%0", "Enter"])
        let pasteLines = await fixture.tmux.controlCommands
            .map(ScriptedTmuxHost.commandList(of:))
            .filter { $0.contains { $0.first == "set-buffer" || $0.first == "paste-buffer" } }
        #expect(pasteLines == [[setBuffer, words[1]]])
        #expect((await fixture.tmux.foregroundScripts).count == 2)
        #expect(await fixture.tmux.buffers.isEmpty)

        await fixture.finish()
    }

    @Test func opensAttachForSendWhenNoneIsLiveAndFailsWhenItDoesNotConnectInTime() async throws {
        let fixture = try await Fixture()
        try await fixture.live()
        await fixture.tmux.breakControlClients()
        try await Fixture.waitUntil("the Attach to end") {
            if case .ended = fixture.attach.terminal.status { return true }
            return false
        }
        #expect(fixture.attach.input.readySession == nil)

        fixture.composer.replaceDraft(with: "woke attach")
        let woke = await fixture.composer.send(policy: fixture.policy)
        #expect(woke == .submittedViaAttach)
        #expect(fixture.composer.draft.isEmpty)

        await fixture.tmux.breakControlClients()
        try await Fixture.waitUntil("the second Attach to end") {
            if case .ended = fixture.attach.terminal.status { return true }
            return false
        }
        await fixture.tmux.silenceNextControlClient()
        fixture.composer.replaceDraft(with: "stalled attach")
        let stalled = Task { await fixture.composer.send(policy: fixture.policy) }
        await fixture.clock.untilParked(for: TmuxComposerSend.liveAttachTimeout)
        fixture.clock.advance(TmuxComposerSend.liveAttachTimeout)
        let stalledResult = await stalled.value

        #expect(stalledResult == .failed)
        #expect(fixture.composer.messages.last?.state == .failed(
            "The terminal did not connect in time, so nothing was sent. Retry when it shows."))
        await fixture.finish()
    }

    // MARK: Bracketed paste (tmux 3.7+ vs < 3.7)

    @Test func readsBracketedPasteFromTmux37FlagAndLiveOutput() async throws {
        let offFixture = try await Fixture(bracketedPaste: false)
        try await offFixture.live()
        offFixture.composer.replaceDraft(with: "keep me")

        let refusedFromFlag = await offFixture.composer.send(policy: offFixture.policy)
        #expect(refusedFromFlag == .refused(.programNotAcceptingPaste))
        #expect(offFixture.composer.draft == "keep me")
        #expect(offFixture.composer.messages.isEmpty)
        #expect(offFixture.composer.notice?.refusal == .programNotAcceptingPaste)
        #expect(await offFixture.sendWords().isEmpty)
        await offFixture.finish()

        let liveFixture = try await Fixture(bracketedPaste: true)
        try await liveFixture.live()
        await liveFixture.tmux.paneOutput("\(Self.escape)[?2004l", in: "%0")
        try await Fixture.waitUntil("mode 2004 off in Attach") {
            let session = try? #require(liveFixture.attach.input.readySession)
            let send = session.flatMap { liveFixture.attach.input.tmuxSend(for: $0) }
            return await send?.bracketedPaste() == .disabled
        }

        liveFixture.composer.replaceDraft(with: "turned off")
        let refusedFromOutput = await liveFixture.composer.send(policy: liveFixture.policy)
        #expect(refusedFromOutput == .refused(.programNotAcceptingPaste))
        #expect(liveFixture.composer.draft == "turned off")
        #expect(await liveFixture.sendWords().isEmpty)

        await liveFixture.tmux.paneOutput("\(Self.escape)[?2004h", in: "%0")
        try await Fixture.waitUntil("mode 2004 on in Attach") {
            let session = try? #require(liveFixture.attach.input.readySession)
            let send = session.flatMap { liveFixture.attach.input.tmuxSend(for: $0) }
            return await send?.bracketedPaste() == .enabled
        }
        let allowedAgain = await liveFixture.composer.send(policy: liveFixture.policy)
        #expect(allowedAgain == .submittedViaAttach)
        #expect(liveFixture.composer.draft.isEmpty)
        await liveFixture.finish()
    }

    @Test func beforeTmux37CountsKnownAgentAsBracketedPasteUntilAttachSeesItTurnedOff() async throws {
        // `bracketedPaste: false` would read `0` on 3.7, whereas 3.3a prints an empty flag.
        let fixture = try await Fixture(version: "tmux 3.3a", bracketedPaste: false)
        try await fixture.live()

        fixture.composer.replaceDraft(with: "first on 3.3a")
        let first = await fixture.composer.send(policy: fixture.policy)
        #expect(first == .submittedViaAttach)
        #expect(fixture.composer.draft.isEmpty)

        await fixture.tmux.paneOutput("\(Self.escape)[?2004l", in: "%0")
        try await Fixture.waitUntil("mode 2004 off on 3.3a") {
            let session = try? #require(fixture.attach.input.readySession)
            let send = session.flatMap { fixture.attach.input.tmuxSend(for: $0) }
            return await send?.bracketedPaste() == .disabled
        }
        let sentBefore = await fixture.sendWords().count

        fixture.composer.replaceDraft(with: "hold draft on 3.3a")
        let refused = await fixture.composer.send(policy: fixture.policy)
        #expect(refused == .refused(.programNotAcceptingPaste))
        #expect(fixture.composer.draft == "hold draft on 3.3a")
        #expect(await fixture.sendWords().count == sentBefore)

        await fixture.tmux.paneOutput("\(Self.escape)[?2004h", in: "%0")
        try await Fixture.waitUntil("mode 2004 back on 3.3a") {
            let session = try? #require(fixture.attach.input.readySession)
            let send = session.flatMap { fixture.attach.input.tmuxSend(for: $0) }
            return await send?.bracketedPaste() == .enabled
        }
        let resumed = await fixture.composer.send(policy: fixture.policy)
        #expect(resumed == .submittedViaAttach)
        #expect(fixture.composer.draft.isEmpty)
        await fixture.finish()
    }

    // MARK: Blocked refusals

    @Test func refusesWhileAgentReadsBlockedBeforeAndAfterPaste() async throws {
        let fixture = try await Fixture(
            pane: .make(
                pane: 0, processID: 4000, command: "claude",
                status: "state=blocked:app=claude-code:turn=0:blocked=1", arguments: ["claude"]))
        try await fixture.live()

        fixture.composer.replaceDraft(with: "blocked before paste")
        let before = await fixture.composer.send(policy: fixture.policy)
        guard case .refused(.inputNotReady(let beforeReason)) = before else {
            Issue.record("Expected pre-paste Blocked refusal, got \(before)")
            await fixture.finish()
            return
        }
        #expect(beforeReason.contains("waiting on its question on screen"))
        #expect(fixture.composer.draft == "blocked before paste")
        #expect(await fixture.sendWords().isEmpty)

        // A stale Blocked option naming another known program does not block Claude Code.
        await fixture.tmux.setPanes([
            .make(
                pane: 0, processID: 4000, command: "claude",
                status: "state=blocked:app=codex:turn=0:blocked=1", arguments: ["claude"]),
        ])
        let foreignBlocked = await fixture.composer.send(policy: fixture.policy)
        #expect(foreignBlocked == .submittedViaAttach)
        #expect(fixture.composer.draft.isEmpty)

        // Entering Blocked while the paste is in flight pastes once and withholds Enter.
        await fixture.tmux.setPanes([
            .make(
                pane: 0, processID: 4000, command: "claude",
                status: "state=idle:app=claude-code:turn=1:blocked=0", arguments: ["claude"]),
        ])
        let wordsBefore = await fixture.sendWords().count
        let tmux = fixture.tmux
        await tmux.afterNextPaste {
            await tmux.setPanes([
                .make(
                    pane: 0, processID: 4000, command: "claude",
                    status: "state=blocked:app=claude-code:turn=1:blocked=1", arguments: ["claude"]),
            ])
        }

        fixture.composer.replaceDraft(with: "blocked after paste")
        let after = await fixture.composer.send(policy: fixture.policy)
        guard case .refused(.notSubmitted(let afterReason)) = after else {
            Issue.record("Expected post-paste Blocked refusal, got \(after)")
            await fixture.finish()
            return
        }
        #expect(afterReason.contains("started asking something"))
        #expect(fixture.composer.draft == "blocked after paste")
        let delta = Array((await fixture.sendWords()).dropFirst(wordsBefore))
        #expect(delta.map(\.first) == ["set-buffer", "paste-buffer"])
        await fixture.finish()
    }

    // MARK: Pre-paste refusals & failures

    @Test func refusesBeforePasteWhenForegroundChangedOrPaneEndedOrServerMovedOn() async throws {
        let fixture = try await Fixture()
        try await fixture.live()

        // Unsafe control byte fails before touching tmux.
        fixture.composer.replaceDraft(with: "bad\u{1B}[2J")
        #expect(await fixture.composer.send(policy: fixture.policy) == .failed)
        #expect(await fixture.sendWords().isEmpty)
        fixture.composer.withdrawToDraft(try #require(fixture.composer.messages.first?.id))

        // Unreadable foreground pid refuses as still starting.
        await fixture.tmux.setForegroundPID(nil, of: "%0")
        fixture.composer.replaceDraft(with: "starting")
        guard case .refused(.inputNotReady(let starting)) = await fixture.composer.send(policy: fixture.policy) else {
            Issue.record("Expected notSampledYet refusal")
            await fixture.finish()
            return
        }
        #expect(starting.contains("still starting"))
        #expect(fixture.composer.draft == "starting")
        #expect(await fixture.sendWords().isEmpty)
        await fixture.tmux.setForegroundPID(4000, of: "%0")

        // Non-agent (`vim`) and shell (`zsh`) refuse before paste and keep draft.
        for (command, args) in [("vim", ["vim", "README.md"]), ("zsh", ["-zsh"])] {
            await fixture.tmux.setPanes([
                .make(pane: 0, processID: 4000, command: command, arguments: args),
            ])
            fixture.composer.replaceDraft(with: "for \(command)")
            guard case .refused(.inputNotReady(let left)) = await fixture.composer.send(policy: fixture.policy) else {
                Issue.record("Expected agentLeft refusal for \(command)")
                await fixture.finish()
                return
            }
            #expect(left.contains("no longer holds this terminal"))
            #expect(fixture.composer.draft == "for \(command)")
            #expect(await fixture.sendWords().isEmpty)
        }

        // Dead pane (`remain-on-exit`) refuses as ended and opens no new control client.
        await fixture.tmux.setPanes([
            .make(pane: 0, processID: 4000, command: "claude", isDead: true, arguments: ["claude"]),
        ])
        try await Fixture.waitUntil("dead snapshot") {
            fixture.console.agents.isEmpty
        }
        fixture.composer.replaceDraft(with: "dead pane")
        guard case .refused(.inputNotReady(let ended)) = await fixture.composer.send(policy: fixture.policy) else {
            Issue.record("Expected agentEnded refusal")
            await fixture.finish()
            return
        }
        #expect(ended.contains("has ended"))
        #expect(fixture.composer.draft == "dead pane")
        #expect(await fixture.sendWords().isEmpty)

        // Replaced tmux server refuses with `tmuxServerGone` message.
        await fixture.tmux.startServer(
            instance: TmuxServerInstance(pid: 9999, startTime: 2_000_000),
            panes: [.make(pane: 0, processID: 5000, command: "claude", arguments: ["claude"])])
        try await Fixture.waitUntil("new server instance") {
            fixture.console.agents.first?.agent.paneID == "%0" && !fixture.corePin.admits("9999:2000000")
        }
        fixture.composer.replaceDraft(with: "wrong server")
        guard case .refused(.inputNotReady(let serverGone)) = await fixture.composer.send(policy: fixture.policy) else {
            Issue.record("Expected serverGone refusal")
            await fixture.finish()
            return
        }
        #expect(serverGone == TransportError.tmuxServerGone.presentation.message)
        #expect(fixture.composer.draft == "wrong server")
        await fixture.finish()
    }

    // MARK: Post-paste foreground changes

    @Test func interruptsShellWithRawCtrlCWhenShellTakesOverAfterPaste() async throws {
        for (shell, args, drops) in [
            ("bash", ["bash"], true),
            ("fish", ["fish"], true),
            ("dash", ["dash"], true),
            ("zsh", ["-zsh"], true),
            ("sh", ["/bin/sh"], false),
            ("ksh", ["ksh"], false),
        ] {
            let fixture = try await Fixture()
            try await fixture.live()
            let tmux = fixture.tmux
            await tmux.afterNextPaste {
                await tmux.setPanes([
                    .make(pane: 0, processID: 4000, command: shell, arguments: args),
                ])
                await tmux.setForegroundPID(4001, of: "%0")
            }

            fixture.composer.replaceDraft(with: "shell takeover \(shell)")
            let outcome = await fixture.composer.send(policy: fixture.policy)
            guard case .refused(.notSubmitted(let reason)) = outcome else {
                Issue.record("Expected post-paste shell refusal for \(shell), got \(outcome)")
                await fixture.finish()
                return
            }
            if drops {
                #expect(reason.contains("no longer in the terminal"))
            } else {
                #expect(reason.contains("may still be in the terminal"))
            }
            #expect(fixture.composer.draft == "shell takeover \(shell)")
            let words = await fixture.sendWords()
            #expect(words.map(\.first) == ["set-buffer", "paste-buffer", "send-keys"])
            #expect(words.last == ["send-keys", "-H", "-t", "%0", "03"])
            #expect(fixture.attach.input.userMessageIndex.entries.isEmpty)
            await fixture.finish()
        }
    }

    @Test func withholdsEnterAndCtrlCWhenOtherChangeOrSlowAnswerOrWriteFailureHappens() async throws {
        // 1. Same program name under a new pid: neither Enter nor Ctrl+C.
        do {
            let fixture = try await Fixture()
            try await fixture.live()
            let tmux = fixture.tmux
            await tmux.afterNextPaste {
                await tmux.setForegroundPID(9001, of: "%0")
            }
            fixture.composer.replaceDraft(with: "restarted agent")
            guard case .refused(.notSubmitted(let reason)) = await fixture.composer.send(policy: fixture.policy) else {
                Issue.record("Expected mayRemain refusal when pid changed")
                await fixture.finish()
                return
            }
            #expect(reason.contains("may still be in the terminal"))
            #expect(fixture.composer.draft == "restarted agent")
            #expect((await fixture.sendWords()).map(\.first) == ["set-buffer", "paste-buffer"])
            await fixture.finish()
        }

        // 2. Non-shell subprogram (`vim`) or unreadable pid after paste: neither Enter nor Ctrl+C.
        for unreadablePID in [false, true] {
            let fixture = try await Fixture()
            try await fixture.live()
            let tmux = fixture.tmux
            await tmux.afterNextPaste {
                if unreadablePID {
                    await tmux.setForegroundPID(nil, of: "%0")
                } else {
                    await tmux.setPanes([
                        .make(pane: 0, processID: 4000, command: "vim", arguments: ["vim"]),
                    ])
                    await tmux.setForegroundPID(4500, of: "%0")
                }
            }
            fixture.composer.replaceDraft(with: "non-shell after paste")
            guard case .refused(.notSubmitted(let reason)) = await fixture.composer.send(policy: fixture.policy) else {
                Issue.record("Expected mayRemain refusal")
                await fixture.finish()
                return
            }
            #expect(reason.contains("may still be in the terminal"))
            #expect(fixture.composer.draft == "non-shell after paste")
            #expect((await fixture.sendWords()).map(\.first) == ["set-buffer", "paste-buffer"])
            await fixture.finish()
        }

        // 3. Pane gone after paste: programEnded, kept draft, no Enter.
        do {
            let fixture = try await Fixture()
            try await fixture.live()
            let tmux = fixture.tmux
            await tmux.afterNextPaste {
                await tmux.setPanes([])
            }
            fixture.composer.replaceDraft(with: "pane closed mid-send")
            guard case .refused(.notSubmitted(let reason)) = await fixture.composer.send(policy: fixture.policy) else {
                Issue.record("Expected programEnded refusal")
                await fixture.finish()
                return
            }
            #expect(reason.contains("ended before the message was submitted"))
            #expect(fixture.composer.draft == "pane closed mid-send")
            #expect((await fixture.sendWords()).map(\.first) == ["set-buffer", "paste-buffer"])
            await fixture.finish()
        }

        // 4. Slow check (>= 2s submitWindow): windowPassed, kept draft, no Enter.
        do {
            let fixture = try await Fixture()
            try await fixture.live()
            let clock = fixture.clock
            await fixture.tmux.afterNextPaste {
                clock.advance(TmuxComposerSend.submitWindow)
            }
            fixture.composer.replaceDraft(with: "late check")
            guard case .refused(.notSubmitted(let reason)) = await fixture.composer.send(policy: fixture.policy) else {
                Issue.record("Expected windowPassed refusal")
                await fixture.finish()
                return
            }
            #expect(reason.contains("answered too slowly"))
            #expect(fixture.composer.draft == "late check")
            #expect((await fixture.sendWords()).map(\.first) == ["set-buffer", "paste-buffer"])
            await fixture.finish()
        }

        // 5. Failed `paste-buffer` deletes Heeler's buffer and fails retryably; failed `Enter` keeps draft.
        do {
            let fixture = try await Fixture()
            try await fixture.live()
            await fixture.tmux.setBuffer("keep user buffer", named: "user-buf")
            await fixture.tmux.failNextPaste()

            fixture.composer.replaceDraft(with: "paste error")
            #expect(await fixture.composer.send(policy: fixture.policy) == .failed)
            try await Fixture.waitUntil("delete-buffer arrives") {
                await fixture.sendWords().map(\.first) == ["set-buffer", "paste-buffer", "delete-buffer"]
            }
            #expect(await fixture.tmux.buffers == ["user-buf": "keep user buffer"])
            fixture.composer.withdrawToDraft(try #require(fixture.composer.messages.first?.id))

            await fixture.tmux.failNextSendKeys()
            fixture.composer.replaceDraft(with: "enter error")
            guard case .refused(.notSubmitted(let reason)) = await fixture.composer.send(policy: fixture.policy) else {
                Issue.record("Expected submitKeyLost refusal")
                await fixture.finish()
                return
            }
            #expect(reason.contains("connection changed before the message was submitted"))
            #expect(fixture.composer.draft == "enter error")
            await fixture.finish()
        }
    }

    // MARK: Unanswered steps, serialization & windows

    @Test func neverResendsUnansweredStepAndWarnsOnceAfterHostAnswersAgain() async throws {
        let fixture = try await Fixture()
        try await fixture.live()

        // Hold control-client replies so `paste-buffer` gets no answer within `stepTimeout`.
        await fixture.tmux.holdControlReplies(true)
        fixture.composer.replaceDraft(with: "unanswered paste")
        let first = Task { await fixture.composer.send(policy: fixture.policy) }
        try await Fixture.waitUntil("paste-buffer written") {
            await fixture.sendWords().contains { $0.first == "paste-buffer" }
        }
        await fixture.clock.untilParked(for: TmuxComposerSend.stepTimeout)
        fixture.clock.advance(TmuxComposerSend.stepTimeout)
        #expect(await first.value == .outcomeUnknown)
        #expect(fixture.composer.messages.first?.state == .outcomeUnknown)
        let pastedCount = await fixture.sendWords().filter { $0.first == "paste-buffer" }.count
        #expect(pastedCount == 1)

        // While control replies remain held, a second Send does not paste behind the stalled one.
        fixture.composer.replaceDraft(with: "blocked behind stalled client")
        let whileStalled = Task { await fixture.composer.send(policy: fixture.policy) }
        try await Fixture.waitUntil("settle probe written") {
            await fixture.controlWords().contains(["display-message", "-p", ""])
        }
        await fixture.clock.untilParked(for: TmuxComposerSend.stepTimeout)
        fixture.clock.advance(TmuxComposerSend.stepTimeout)
        #expect(await whileStalled.value == .failed)
        #expect(await fixture.sendWords().filter { $0.first == "paste-buffer" }.count == 1)
        fixture.composer.withdrawToDraft(try #require(fixture.composer.messages.last?.id))

        // Once the Host answers again, the next Send warns once and keeps the draft; the one after goes.
        await fixture.tmux.holdControlReplies(false)
        fixture.composer.replaceDraft(with: "after recovery")
        guard case .refused(.inputNotReady(let warning)) = await fixture.composer.send(policy: fixture.policy) else {
            Issue.record("Expected one-time lastSendMayRemain notice")
            await fixture.finish()
            return
        }
        #expect(warning.contains("last message may still be in the Agent's input"))
        #expect(fixture.composer.draft == "after recovery")
        #expect(await fixture.sendWords().filter { $0.first == "paste-buffer" }.count == 1)

        #expect(await fixture.composer.send(policy: fixture.policy) == .submittedViaAttach)
        #expect(fixture.composer.draft.isEmpty)
        #expect(await fixture.sendWords().filter { $0.first == "paste-buffer" }.count == 2)
        await fixture.finish()
    }

    @Test func serializesConcurrentSendsAndRoutesEachWindowsAttach() async throws {
        let fixture = try await Fixture()
        try await fixture.live()
        let otherAttach = try await fixture.openOtherWindow()
        defer { Task { await otherAttach.leave().value } }

        // Hold control replies during the first paste so a concurrent second Send queues behind it.
        await fixture.tmux.holdControlReplies(true)
        fixture.composer.replaceDraft(with: "first")
        let first = Task { await fixture.composer.send(policy: fixture.policy) }
        try await Fixture.waitUntil("first paste written") {
            await fixture.sendWords().contains { $0.first == "paste-buffer" }
        }

        var otherPolicy = ComposerDeliveryPolicy.terminal
        otherPolicy.coreAttach = otherAttach
        fixture.composer.replaceDraft(with: "second")
        let second = Task { await fixture.composer.send(policy: otherPolicy) }
        try await Task.sleep(for: .milliseconds(30))
        // Second has not set its buffer while first is still in flight.
        #expect(await fixture.sendWords().filter { $0.first == "set-buffer" }.count == 1)

        await fixture.tmux.holdControlReplies(false)
        #expect(await first.value == .submittedViaAttach)
        #expect(await second.value == .submittedViaAttach)

        let words = await fixture.sendWords()
        #expect(words.map(\.first) == [
            "set-buffer", "paste-buffer", "send-keys",
            "set-buffer", "paste-buffer", "send-keys",
        ])
        let firstBuffer = words[0][2]
        let secondBuffer = words[3][2]
        #expect(firstBuffer != secondBuffer)
        #expect(words[0].last == "first")
        #expect(words[3].last == "second")
        await fixture.finish()
    }

    @Test func clientEndingMidPasteLeavesNoHeelerBufferAndReportsOutcomeUnknown() async throws {
        let fixture = try await Fixture()
        try await fixture.live()
        await fixture.tmux.setBuffer("the user's", named: "buffer0")
        await fixture.tmux.breakControlClientOnNextPasteWrite()

        fixture.composer.replaceDraft(with: "sensitive draft ; with quotes \"x\"")
        let outcome = await fixture.composer.send(policy: fixture.policy)
        #expect(outcome == .outcomeUnknown)
        #expect(fixture.composer.messages.first?.state == .outcomeUnknown)
        #expect(await fixture.tmux.buffers == ["buffer0": "the user's"])
        await fixture.finish()

        // Also cover a server `%exit` while `paste-buffer` is held in flight: the paste
        // already started, so Composer reports `.outcomeUnknown`, not `.failed` ("not sent").
        let second = try await Fixture()
        try await second.live()
        await second.tmux.setBuffer("the user's", named: "buffer0")
        await second.tmux.holdControlReplies(true)
        second.composer.replaceDraft(with: "in flight before exit")
        let sending = Task { await second.composer.send(policy: second.policy) }
        try await Fixture.waitUntil("paste written") {
            await second.sendWords().contains { $0.first == "paste-buffer" }
        }
        #expect(await second.tmux.buffers == ["buffer0": "the user's"])
        await second.tmux.stopServer()
        #expect(await sending.value == .outcomeUnknown)
        #expect(second.composer.messages.first?.state == .outcomeUnknown)
        await second.tmux.holdControlReplies(false)
        await second.finish()
    }
}
