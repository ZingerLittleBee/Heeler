import Foundation
import Testing

@testable import Heeler

/// Chat's Send, Stop, tools keyboard and Blocked Card answers on a tmux Host
/// (ADRs 0035, 0043 and 0044), from `AgentComposerStore`, `BlockedCardStore` and
/// `ChatAgentKeysStore` down through `ConsoleStore`, `TmuxConsoleProjection`,
/// `TmuxChatTyping` and `TmuxSSHTransport` over `ScriptedTmuxHost`.
@MainActor
@Suite("tmux Chat Typing", .timeLimit(.minutes(1)))
struct TmuxChatTypingTests {
    private static let readyScreen = "claude-01-ready"
    private static let dialogScreen = "claude-02-c1-bash-blocked"

    @MainActor
    private struct Fixture {
        let tmux: ScriptedTmuxHost
        let console: ConsoleStore
        let host: Host
        let clock = ManualClock()
        let composer: AgentComposerStore
        let corePin: TerminalCorePin
        let agent: ConsoleAgent

        init(
            version: String = "tmux 3.7b",
            kernel: String = "Linux",
            command: String = "claude",
            app: String = "claude-code",
            state: String = "idle",
            turn: Int = 2,
            blocked: Int = 1,
            width: Int = 112,
            height: Int = 40,
            bracketedPaste: Bool = true,
            screen: String? = TmuxChatTypingTests.readyScreen
        ) async throws {
            let status = "state=\(state):app=\(app):turn=\(turn):blocked=\(blocked)"
            let tmux = ScriptedTmuxHost(version: version, kernel: kernel)
            let pane = TmuxInventory.Pane.make(
                pane: 0, processID: 4000, command: command, width: width, height: height,
                status: status, arguments: [command])
            await tmux.setPanes([pane])
            await tmux.setBracketedPaste(bracketedPaste, of: "%0")
            if let screen {
                try await Self.setScreen(screen, on: tmux)
            }
            self.tmux = tmux
            let host = Host(
                address: "box.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())
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
                    defaults: UserDefaults(suiteName: "tmux-chat-typing-\(UUID().uuidString)") ?? .standard),
                coreSendClock: BlockedCardClock(now: clock.clock.now, sleep: clock.parkedSleep(for:)))
            self.console = console
            console.setHosts([host])
            await console.resume()
            try await Self.waitUntil("the Agent and kernel") { [console] in
                !console.agents.isEmpty && console.capabilities(for: host.id).offersChat(for: .claude)
            }
            let agent = try #require(console.agents.first)
            self.agent = agent
            let session = console.composerSession(for: agent)
            composer = session.composer
            corePin = session.corePin
            composer.open()
        }

        static func setScreen(_ stem: String, on tmux: ScriptedTmuxHost, pane: String = "%0") async throws {
            let raw = try ScreenFixture.text(stem)
            await setRawScreen(raw, on: tmux, pane: pane)
        }

        static func setRawScreen(_ raw: String, on tmux: ScriptedTmuxHost, pane: String = "%0") async {
            var lines = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if lines.last?.isEmpty == true { lines.removeLast() }
            await tmux.setScreen(lines, of: pane)
        }

        func policy(
            program: ChatProgram = .claude,
            activity: @escaping @Sendable () -> ChatAgentActivity = { .idle }
        ) -> ComposerDeliveryPolicy {
            let console = console
            let hostID = host.id
            let corePin = corePin
            return .chat(
                rules: ChatSendRules(
                    program: program,
                    commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: program)),
                activity: activity,
                readScreen: { try await console.readAgentScreen("%0", on: hostID, keepingTo: corePin) },
                pause: { _ in })
        }

        func sendChat(
            _ draft: String = "hello",
            program: ChatProgram = .claude,
            activity: (@Sendable () -> ChatAgentActivity)? = nil
        ) async -> AgentComposerStore.SendResult {
            composer.replaceDraft(with: draft)
            return await composer.send(policy: policy(program: program, activity: activity ?? { .idle }))
        }

        func agentKeys() -> ChatAgentKeysStore {
            let console = console
            let hostID = host.id
            let corePin = corePin
            return ChatAgentKeysStore { keys in
                try await console.sendAgentKeys(keys, to: "%0", on: hostID, keepingTo: corePin)
            }
        }

        func chatStop(
            program: ChatProgram = .claude,
            activity: ChatAgentActivity = .working
        ) -> AgentComposerInterrupt {
            let console = console
            let hostID = host.id
            let corePin = corePin
            let keys = agentKeys()
            return console.chatInterrupt(
                for: agent,
                program: program,
                keepingTo: corePin,
                context: {
                    let screen = try await console.readAgentScreen("%0", on: hostID, keepingTo: corePin)
                    return ChatStopContext(screen: screen, activity: activity)
                },
                agentKeys: keys)
        }

        func blockedCard(program: ChatProgram = .claude) async throws -> BlockedCardStore {
            let chat = try #require(console.chatStore(for: agent, program: program))
            chat.blocked.update(activity: .blocked)
            await chat.blocked.refresh()
            return chat.blocked
        }

        func controlWords(after mark: Int = 0) async -> [[String]] {
            await tmux.controlCommands.dropFirst(mark).flatMap(ScriptedTmuxHost.commandList(of:))
        }

        func sendWords(after mark: Int = 0) async -> [[String]] {
            await controlWords(after: mark).filter { words in
                guard let first = words.first else { return false }
                return ["set-buffer", "paste-buffer", "delete-buffer", "send-keys"].contains(first)
            }
        }

        func finish() {
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

    // MARK: Chat's own size-less Attach and screen reads

    @Test func chatAttachAsksForNoSizeClosesAfterEachActionAndLeavesWindowSizeUnchanged() async throws {
        let fixture = try await Fixture(width: 112, height: 40)
        await fixture.tmux.setDesktopClients([
            .init(windowID: "@0", width: 112, height: 41),
        ])
        #expect(await fixture.tmux.windowSize("@0") == (112, 40))

        // 1. Chat Send opens a size-less Attach, sends, and detaches immediately.
        let sendResult = await fixture.sendChat("hello")
        #expect(sendResult == .submittedViaAttach)
        #expect(await fixture.tmux.openControlClients == 0)
        #expect(await fixture.tmux.attachSessions.isEmpty)
        #expect(await fixture.tmux.windowSize("@0") == (112, 40))

        // 2. Chat Stop opens a size-less Attach, sends Escape, and detaches immediately.
        await fixture.tmux.setPanes([
            .make(
                pane: 0, processID: 4000, command: "claude", width: 112, height: 40,
                status: "state=working:app=claude-code:turn=2:blocked=1", arguments: ["claude"]),
        ])
        let stopOutcome = await fixture.chatStop().perform()
        #expect(stopOutcome == .sent)
        #expect(await fixture.tmux.openControlClients == 0)
        #expect(await fixture.tmux.windowSize("@0") == (112, 40))

        // 3. Tools keyboard and pasteIntoAgent also close immediately and leave window size intact.
        try await fixture.console.sendAgentKeys(["down"], to: "%0", on: fixture.host.id, keepingTo: fixture.corePin)
        #expect(await fixture.tmux.openControlClients == 0)
        #expect(await fixture.tmux.windowSize("@0") == (112, 40))

        try await fixture.console.pasteIntoAgent("note", paneID: "%0", on: fixture.host.id)
        #expect(await fixture.tmux.openControlClients == 0)
        #expect(await fixture.tmux.windowSize("@0") == (112, 40))

        // 4. Blocked Card answer with no DesktopClient attached also leaves window size at 112x40.
        await fixture.tmux.setDesktopClients([])
        await fixture.tmux.setPanes([
            .make(
                pane: 0, processID: 4000, command: "claude", width: 112, height: 40,
                status: "state=blocked:app=claude-code:turn=2:blocked=2", arguments: ["claude"]),
        ])
        try await Fixture.setScreen(Self.dialogScreen, on: fixture.tmux)
        let card = try await fixture.blockedCard()
        let answering = Task { await card.perform(.choose(ordinal: 1)) }
        try await Fixture.waitUntil("digit 1 sent") {
            await fixture.sendWords().contains(["send-keys", "-l", "-t", "%0", "--", "1"])
        }
        try await Fixture.setScreen(Self.readyScreen, on: fixture.tmux)
        await answering.value
        #expect(await fixture.tmux.openControlClients == 0)
        #expect(await fixture.tmux.windowSize("@0") == (112, 40))

        // Every control client ever opened used ignore-size and never requested -C.
        let allControl = await fixture.controlWords()
        #expect(allControl.contains(["refresh-client", "-f", "ignore-size"]))
        #expect(!allControl.contains { $0.first == "refresh-client" && $0.contains("-C") })

        fixture.finish()
    }

    @Test func screenReadsRunCapturePaneWithEscapesOnHostSocketWithoutOpeningAttach() async throws {
        let fixture = try await Fixture(state: "blocked", screen: Self.dialogScreen)
        await fixture.tmux.clearLog()

        let screen = try await fixture.console.readAgentScreen("%0", on: fixture.host.id, keepingTo: fixture.corePin)
        let expected = try ScreenFixture.screen(Self.dialogScreen)
        let comparableCount = min(screen.rows.count, expected.rows.count)
        #expect(
            screen.rows.prefix(comparableCount).map(\.trimmedText)
                == expected.rows.prefix(comparableCount).map(\.trimmedText))
        #expect(screen.rows.contains { row in row.runs.contains { $0.style != .plain } })
        #expect(await fixture.tmux.controlScripts.isEmpty)
        let commands = await fixture.tmux.commands
        #expect(commands.contains { $0.contains("capture-pane") && $0.contains("-e") && $0.contains("-p") })

        let card = try await fixture.blockedCard()
        guard case .card(let shown) = card.content else {
            Issue.record("Expected parsed BlockedCard from capture-pane -e -p, got \(card.content)")
            fixture.finish()
            return
        }
        #expect(shown.dialog.kind == .claudeBash)
        #expect(await fixture.tmux.controlScripts.isEmpty)

        fixture.finish()
    }

    @Test func serverInstanceReplacementRefusesOpenDetailsChatActionsAndAdmitsNewOnes() async throws {
        let fixture = try await Fixture(state: "blocked", screen: Self.dialogScreen)
        let oldPin = fixture.corePin
        let oldComposer = fixture.composer
        let oldAgent = fixture.agent
        let oldChat = try #require(fixture.console.chatStore(for: oldAgent, program: .claude))
        let oldCard = try await fixture.blockedCard()
        let oldStop = fixture.chatStop()
        let controlCountBefore = await fixture.tmux.controlCommands.count

        // Replace the server on the same socket as the Blocked Card opens its Attach:
        // the post-open check sees the replacement instance, types nothing, and closes.
        let replacement = TmuxServerInstance(pid: 9999, startTime: 1_794_400_000)
        let tmux = fixture.tmux
        await tmux.afterNextControlClientStart {
            await tmux.startServer(
                instance: replacement,
                panes: [
                    .make(
                        pane: 0, processID: 5000, command: "claude", width: 112, height: 40,
                        status: "state=idle:app=claude-code:turn=0:blocked=0", arguments: ["claude"]),
                ])
            await tmux.setBracketedPaste(true, of: "%0")
            try? await Fixture.setScreen(Self.readyScreen, on: tmux)
        }
        await oldCard.perform(.choose(ordinal: 1))
        #expect(await fixture.sendWords(after: controlCountBefore).isEmpty)

        try await Fixture.waitUntil("replacement server adopted") {
            fixture.console.hasLeftCore(oldPin, on: fixture.host.id) && !fixture.console.agents.isEmpty
        }
        await fixture.tmux.clearLog()

        // ConsoleStore retired the old instance's AgentChatStore and cleared its BlockedCard.
        #expect(oldCard.content == .none)

        // Old detail's screen read, Send, Stop and tools keys all refuse cleanly without typing.
        await #expect(throws: TransportError.tmuxServerGone) {
            _ = try await fixture.console.readAgentScreen("%0", on: fixture.host.id, keepingTo: oldPin)
        }

        oldComposer.replaceDraft(with: "wrong server")
        let oldSend = await oldComposer.send(
            policy: .chat(
                rules: ChatSendRules(
                    program: .claude,
                    commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .claude)),
                activity: { .idle },
                readScreen: { try ScreenFixture.screen(Self.readyScreen) },
                pause: { _ in }))
        guard case .refused(.inputNotReady(let sendReason)) = oldSend else {
            Issue.record("Expected serverGone refusal on old Composer, got \(oldSend)")
            fixture.finish()
            return
        }
        #expect(sendReason == TransportError.tmuxServerGone.presentation.message)

        let oldStopOutcome = await oldStop.perform()
        #expect(oldStopOutcome != .sent)

        await #expect(throws: HerdrCoreChatTyping.Refusal.self) {
            try await fixture.console.sendAgentKeys(["esc"], to: "%0", on: fixture.host.id, keepingTo: oldPin)
        }
        #expect(await fixture.sendWords(after: controlCountBefore).isEmpty)

        // Opening a fresh Chat and Composer on the new server's row creates a new store and sends normally.
        let newAgent = try #require(fixture.console.agents.first { $0.id == oldAgent.id })
        let newChat = try #require(fixture.console.chatStore(for: newAgent, program: .claude))
        #expect(newChat !== oldChat)
        let newSession = fixture.console.composerSession(for: newAgent)
        #expect(!newSession.corePin.keepsToSameCore(as: oldPin))
        newSession.composer.open()
        newSession.composer.replaceDraft(with: "right server")
        let newSend = await newSession.composer.send(
            policy: .chat(
                rules: ChatSendRules(
                    program: .claude,
                    commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .claude)),
                activity: { .idle },
                readScreen: {
                    try await fixture.console.readAgentScreen("%0", on: fixture.host.id, keepingTo: newSession.corePin)
                },
                pause: { _ in }))
        #expect(newSend == .submittedViaAttach)
        #expect(await fixture.tmux.openControlClients == 0)

        fixture.finish()
    }

    // MARK: Chat Send

    @Test func chatSendSubmitsThroughNamedBufferAndRefusesBlockedOrUnbracketedPaste() async throws {
        // 1. Blocked Agent refuses with .agentBlocked (both at preflight and if @heeler-status turned
        // blocked before the foreground read) without opening a control client.
        do {
            let blocked = try await Fixture(state: "blocked", screen: Self.readyScreen)
            await blocked.tmux.clearLog()
            let preflightRefused = await blocked.sendChat("blocked at preflight", activity: { .blocked })
            #expect(preflightRefused == .refused(.agentBlocked))
            #expect(blocked.composer.draft == "blocked at preflight")
            let foregroundRefused = await blocked.sendChat("blocked message")
            #expect(foregroundRefused == .refused(.agentBlocked))
            #expect(blocked.composer.draft == "blocked message")
            #expect(await blocked.tmux.controlScripts.isEmpty)
            blocked.finish()
        }

        // 2. Non-empty input box on screen refuses before opening a control client.
        do {
            let draft = try await Fixture(command: "grok", app: "grok-build", height: 47, screen: "grok-02-idle-draft")
            let result = await draft.sendChat("behind draft", program: .grok)
            guard case .refused(.inputNotReady(let reason)) = result else {
                Issue.record("Expected refusal over input box draft, got \(result)")
                draft.finish()
                return
            }
            #expect(reason.contains("already has text"))
            #expect(draft.composer.draft == "behind draft")
            #expect(await draft.tmux.controlScripts.isEmpty)
            draft.finish()
        }

        // 3. tmux 3.7b with bracket_paste_flag == 0 refuses .programNotAcceptingPaste and closes Attach.
        do {
            let unbracketed = try await Fixture(version: "tmux 3.7b", bracketedPaste: false)
            let result = await unbracketed.sendChat("unbracketed")
            #expect(result == .refused(.programNotAcceptingPaste))
            #expect(unbracketed.composer.draft == "unbracketed")
            #expect(await unbracketed.sendWords().isEmpty)
            #expect(await unbracketed.tmux.openControlClients == 0)
            unbracketed.finish()
        }

        // 4. tmux 3.3a (no bracket_paste_flag format) allows paste for a known Agent and closes Attach.
        do {
            let tmux33 = try await Fixture(version: "tmux 3.3a", bracketedPaste: false)
            let result = await tmux33.sendChat("hello")
            #expect(result == .submittedViaAttach)
            let words = await tmux33.sendWords()
            #expect(words.count == 3)
            let setBuffer = try #require(words.first)
            let bufferName = try #require(setBuffer.dropFirst(2).first)
            // Chat's send rules append one trailing space on Claude Code.
            #expect(setBuffer == ["set-buffer", "-b", bufferName, "--", "hello "])
            #expect(words[1] == ["paste-buffer", "-p", "-r", "-d", "-b", bufferName, "-t", "%0"])
            #expect(words[2] == ["send-keys", "-t", "%0", "Enter"])
            #expect(await tmux33.tmux.openControlClients == 0)
            tmux33.finish()
        }
    }

    @Test func chatSendGuardsAgainstForegroundChangesDuringOpenAndAfterPaste() async throws {
        // 1. Another process takes over while Chat's Attach opens: types nothing and closes Attach.
        do {
            let fixture = try await Fixture()
            let tmux = fixture.tmux
            await tmux.afterNextControlClientStart {
                await tmux.setForegroundPID(9001, of: "%0")
            }
            let result = await fixture.sendChat("hello")
            guard case .refused(.inputNotReady(let reason)) = result else {
                Issue.record("Expected holderChangedWhileOpening refusal, got \(result)")
                fixture.finish()
                return
            }
            #expect(reason.contains("Another process took over"))
            #expect(await fixture.sendWords().isEmpty)
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }

        // 2. Shell takes over after paste: withholds Enter, sends 0x03, closes Attach.
        do {
            let fixture = try await Fixture()
            let tmux = fixture.tmux
            await tmux.afterNextPaste {
                await tmux.setPanes([
                    .make(pane: 0, processID: 4000, command: "zsh", width: 112, height: 34, arguments: ["-zsh"]),
                ])
                await tmux.setForegroundPID(4001, of: "%0")
            }
            let result = await fixture.sendChat("hello")
            guard case .refused(.notSubmitted(let reason)) = result else {
                Issue.record("Expected dropped-paste refusal, got \(result)")
                fixture.finish()
                return
            }
            #expect(reason.contains("no longer in the terminal"))
            let words = await fixture.sendWords()
            #expect(words.contains(["send-keys", "-H", "-t", "%0", "03"]))
            #expect(!words.contains(["send-keys", "-t", "%0", "Enter"]))
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }

        // 3. Submit window passes after paste: withholds Enter and closes Attach.
        do {
            let fixture = try await Fixture()
            let clock = fixture.clock
            await fixture.tmux.afterNextPaste {
                _ = await MainActor.run {
                    clock.advance(TmuxComposerSend.submitWindow)
                }
            }
            let result = await fixture.sendChat("hello")
            guard case .refused(.notSubmitted(let reason)) = result else {
                Issue.record("Expected windowPassed refusal, got \(result)")
                fixture.finish()
                return
            }
            #expect(reason.contains("stayed in the Agent's input unsubmitted"))
            #expect(!(await fixture.sendWords()).contains(["send-keys", "-t", "%0", "Enter"]))
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }

        // 4. Broken paste write yields .outcomeUnknown, and the next Chat Send settles once.
        do {
            let fixture = try await Fixture()
            await fixture.tmux.breakControlClientOnNextPasteWrite()
            let first = await fixture.sendChat("uncertain")
            #expect(first == .outcomeUnknown)
            #expect(await fixture.tmux.openControlClients == 0)

            let second = await fixture.sendChat("follow-up")
            guard case .refused(.inputNotReady(let settleReason)) = second else {
                Issue.record("Expected lastSendMayRemain warning, got \(second)")
                fixture.finish()
                return
            }
            #expect(settleReason.contains("last message may still be"))

            let third = await fixture.sendChat("follow-up")
            #expect(third == .submittedViaAttach)
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }
    }

    // MARK: Chat Stop

    @Test func chatStopRunsProgramPlanThroughChatsOwnAttachAndWritesIdle() async throws {
        // 1. Claude Code Stop while Blocked sends Escape, writes idle, clears @heeler-ask, closes Attach.
        do {
            let claude = try await Fixture(state: "blocked", turn: 3, blocked: 2)
            await claude.tmux.setAsk("4000 ask-1", of: "%0")
            let outcome = await claude.chatStop(program: .claude, activity: .blocked).perform()
            #expect(outcome == .sent)
            #expect(await claude.sendWords() == [["send-keys", "-t", "%0", "Escape"]])
            #expect(await claude.tmux.status(of: "%0") == "state=idle:app=claude-code:turn=3:blocked=2")
            #expect(await claude.tmux.ask(of: "%0") == "")
            #expect(await claude.tmux.openControlClients == 0)
            claude.finish()
        }

        // 2. OpenCode Stop sends two Escapes on running turn and advances turn; refuses while Blocked.
        do {
            let opencode = try await Fixture(
                command: "opencode", app: "opencode", state: "working", turn: 0, blocked: 0, height: 41,
                screen: "opencode-35-working-62")
            let outcome = await opencode.chatStop(program: .opencode, activity: .working).perform()
            #expect(outcome == .sent)
            #expect(
                await opencode.sendWords() == [
                    ["send-keys", "-t", "%0", "Escape"],
                    ["send-keys", "-t", "%0", "Escape"],
                ])
            #expect(await opencode.tmux.status(of: "%0") == "state=idle:app=opencode:turn=1:blocked=0")
            #expect(await opencode.tmux.openControlClients == 0)

            await opencode.tmux.setPanes([
                .make(
                    pane: 0, processID: 4000, command: "opencode", width: 112, height: 41,
                    status: "state=blocked:app=opencode:turn=1:blocked=1", arguments: ["opencode"]),
            ])
            try await Fixture.waitUntil("OpenCode status blocked") {
                opencode.console.agents.first?.agent.status == .blocked
            }
            let mark = await opencode.tmux.controlCommands.count
            let blockedOutcome = await opencode.chatStop(program: .opencode, activity: .blocked).perform()
            #expect(blockedOutcome == .failed("The turn already ended, so Stop pressed nothing."))
            #expect(await opencode.sendWords(after: mark).isEmpty)
            #expect(await opencode.tmux.status(of: "%0") == "state=blocked:app=opencode:turn=1:blocked=1")
            #expect(await opencode.tmux.openControlClients == 0)
            opencode.finish()
        }

        // 3. Grok Build Stop sends C-c on running turn; refuses while Blocked.
        do {
            let grok = try await Fixture(
                command: "grok", app: "grok-build", state: "working", turn: 0, blocked: 0, height: 20,
                screen: "grok-32-working-62x20")
            let outcome = await grok.chatStop(program: .grok, activity: .working).perform()
            #expect(outcome == .sent)
            #expect(await grok.sendWords() == [["send-keys", "-t", "%0", "C-c"]])
            #expect(await grok.tmux.status(of: "%0") == "state=idle:app=grok-build:turn=0:blocked=0")
            #expect(await grok.tmux.openControlClients == 0)
            grok.finish()
        }

        // 4. Shell taking over while Chat's Attach opens presses nothing and writes nothing.
        do {
            let fixture = try await Fixture(state: "working", turn: 2, blocked: 0)
            let before = try #require(await fixture.tmux.status(of: "%0"))
            let tmux = fixture.tmux
            await tmux.afterNextControlClientStart {
                await tmux.setPanes([
                    .make(
                        pane: 0, processID: 4000, command: "zsh", width: 112, height: 40,
                        status: before, arguments: ["-zsh"]),
                ])
                await tmux.setForegroundPID(4001, of: "%0")
            }
            let outcome = await fixture.chatStop().perform()
            #expect(outcome != .sent)
            #expect(await fixture.sendWords().isEmpty)
            #expect(await fixture.tmux.status(of: "%0") == before)
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }
    }

    // MARK: Blocked Card answers and status writes

    @Test func blockedCardChecksDialogAndForegroundAndWritesIdleOrWorkingAfterAnswer() async throws {
        // 1. Approving writes working and clears @heeler-ask.
        do {
            let fixture = try await Fixture(state: "blocked", turn: 4, blocked: 2, screen: Self.dialogScreen)
            await fixture.tmux.setAsk("4000 bash-1", of: "%0")
            let card = try await fixture.blockedCard()

            let answering = Task { await card.perform(.choose(ordinal: 1)) }
            try await Fixture.waitUntil("digit 1 sent") {
                await fixture.sendWords().contains(["send-keys", "-l", "-t", "%0", "--", "1"])
            }
            try await Fixture.setScreen(Self.readyScreen, on: fixture.tmux)
            await answering.value

            #expect(card.notice == nil)
            #expect(await fixture.tmux.status(of: "%0") == "state=working:app=claude-code:turn=4:blocked=2")
            #expect(await fixture.tmux.ask(of: "%0") == "")
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }

        // 2. Declining option (`No`) writes idle and clears @heeler-ask.
        do {
            let fixture = try await Fixture(state: "blocked", turn: 4, blocked: 2, screen: Self.dialogScreen)
            await fixture.tmux.setAsk("4000 bash-2", of: "%0")
            let card = try await fixture.blockedCard()
            guard case .card(let shown) = card.content,
                let decline = shown.dialog.options.first(where: { $0.role == .decline })
            else {
                Issue.record("Expected decline option on Claude bash dialog")
                fixture.finish()
                return
            }

            let answering = Task { await card.perform(.choose(ordinal: decline.ordinal)) }
            try await Fixture.waitUntil("decline digit sent") {
                await !fixture.sendWords().isEmpty
            }
            try await Fixture.setScreen("claude-25-c8-after-digit3", on: fixture.tmux)
            await answering.value

            #expect(card.notice == nil)
            #expect(await fixture.tmux.status(of: "%0") == "state=idle:app=claude-code:turn=4:blocked=2")
            #expect(await fixture.tmux.ask(of: "%0") == "")
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }

        // 3. Dialog changing while Chat's Attach opens types nothing and leaves status/ask alone.
        do {
            let fixture = try await Fixture(state: "blocked", turn: 4, blocked: 2, screen: "claude-30-par-first")
            let beforeStatus = await fixture.tmux.status(of: "%0")
            await fixture.tmux.setAsk("4000 par-1", of: "%0")
            let card = try await fixture.blockedCard()
            let tmux = fixture.tmux
            await tmux.afterNextControlClientStart {
                try? await Fixture.setScreen("claude-31-par-second", on: tmux)
            }

            await card.perform(.choose(ordinal: 1))

            #expect(card.notice == BlockedCardStore.changedMessage)
            #expect(await fixture.sendWords().isEmpty)
            #expect(await fixture.tmux.status(of: "%0") == beforeStatus)
            #expect(await fixture.tmux.ask(of: "%0") == "4000 par-1")
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }

        // 4. Another foreground process after readScreen refuses until refreshed, then succeeds.
        do {
            let fixture = try await Fixture(state: "blocked", turn: 1, blocked: 1, screen: Self.dialogScreen)
            let beforeStatus = await fixture.tmux.status(of: "%0")
            let card = try await fixture.blockedCard()
            await fixture.tmux.setForegroundPID(4001, of: "%0")

            await card.perform(.choose(ordinal: 1))
            #expect(card.notice?.contains("Another process took over") == true, "\(card.notice ?? "")")
            #expect(await fixture.sendWords().isEmpty)
            #expect(await fixture.tmux.status(of: "%0") == beforeStatus)

            await card.refresh()
            let answering = Task { await card.perform(.choose(ordinal: 1)) }
            try await Fixture.waitUntil("digit 1 sent after refresh") {
                await fixture.sendWords().contains(["send-keys", "-l", "-t", "%0", "--", "1"])
            }
            try await Fixture.setScreen(Self.readyScreen, on: fixture.tmux)
            await answering.value
            #expect(await fixture.tmux.status(of: "%0") == "state=working:app=claude-code:turn=1:blocked=1")
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }
    }

    @Test func toolsKeyboardAndKeyPadRecordOnlyBlockedClaudeEscapeAndWriteNothingForUnknownEnter() async throws {
        // 1. Blocked Claude Code: navigation and unknown-selection Enter write nothing; Esc writes idle.
        let fixture = try await Fixture(
            state: "blocked", turn: 5, blocked: 3, height: 41, screen: "claude-42-c8-phone-question-previews")
        let initialStatus = try #require(await fixture.tmux.status(of: "%0"))
        await fixture.tmux.setAsk("4000 preview-q", of: "%0")

        let keys = fixture.agentKeys()
        #expect(await keys.deliver(["down"]) == .sent)
        #expect(await fixture.tmux.status(of: "%0") == initialStatus)
        #expect(await fixture.tmux.ask(of: "%0") == "4000 preview-q")

        // Unknown-selection Enter from Chat's tools keyboard writes nothing.
        #expect(await keys.deliver(["enter"]) == .sent)
        #expect(await fixture.tmux.status(of: "%0") == initialStatus)
        #expect(await fixture.tmux.ask(of: "%0") == "4000 preview-q")

        // Unknown-selection Enter from BlockedCardStore's key pad also writes nothing.
        let card = try await fixture.blockedCard()
        await card.sendKeys(["down"])
        await card.sendKeys(["enter"])
        #expect(await fixture.tmux.status(of: "%0") == initialStatus)
        #expect(await fixture.tmux.ask(of: "%0") == "4000 preview-q")

        // Extended key without extended pane_key_mode refuses cleanly without typing S-Enter;
        // once Ext 1 is active, it sends S-Enter.
        guard case .withheld = await keys.deliver(["shift+enter"]) else {
            Issue.record("Expected shift+enter to be withheld in VT10x mode")
            fixture.finish()
            return
        }
        await fixture.tmux.setKeyMode("Ext 1", of: "%0")
        #expect(await keys.deliver(["shift+enter"]) == .sent)
        #expect(await fixture.sendWords().contains(["send-keys", "-t", "%0", "S-Enter"]))

        // Key-pad Esc while Claude Code is Blocked declines: writes idle and clears @heeler-ask.
        await card.sendKeys(["esc"])
        #expect(await fixture.tmux.status(of: "%0") == "state=idle:app=claude-code:turn=5:blocked=3")
        #expect(await fixture.tmux.ask(of: "%0") == "")

        // Reset back to Blocked and verify tools-keyboard Esc also writes idle and clears @heeler-ask.
        await fixture.tmux.setPanes([
            .make(
                pane: 0, processID: 4000, command: "claude", width: 112, height: 41,
                status: "state=blocked:app=claude-code:turn=5:blocked=4", arguments: ["claude"]),
        ])
        await fixture.tmux.setAsk("4000 preview-q2", of: "%0")
        try await Fixture.waitUntil("Claude blocked again") {
            fixture.console.agents.first?.agent.status == .blocked
        }
        #expect(await keys.deliver(["esc"]) == .sent)
        #expect(await fixture.tmux.status(of: "%0") == "state=idle:app=claude-code:turn=5:blocked=4")
        #expect(await fixture.tmux.ask(of: "%0") == "")
        #expect(await fixture.tmux.openControlClients == 0)

        fixture.finish()
    }

    @Test func blockedCardWritesIdleForDeclinesWorkingForKnownAnswersAndNothingForUnknownChoices() async throws {
        // 1. Recognized card: dismiss (Esc) writes idle; unknown .choose ordinal writes nothing.
        do {
            let fixture = try await Fixture(state: "blocked", turn: 4, blocked: 2, screen: Self.dialogScreen)
            let initialStatus = try #require(await fixture.tmux.status(of: "%0"))
            await fixture.tmux.setAsk("4000 ask-dismiss", of: "%0")
            let card = try await fixture.blockedCard()

            // Unknown .choose ordinal sends nothing and writes nothing.
            await card.perform(.choose(ordinal: 99))
            #expect(await fixture.sendWords().isEmpty)
            #expect(await fixture.tmux.status(of: "%0") == initialStatus)
            #expect(await fixture.tmux.ask(of: "%0") == "4000 ask-dismiss")

            // Direct .unknown answer on TmuxChatTyping's BlockedScreenIO also writes nothing.
            let typing = try #require(fixture.console.tmuxProjection(on: fixture.host.id)?.checkedChatTyping(at: "%0"))
            await typing.blockedScreen.recordAnswer?(.unknown)
            #expect(await fixture.tmux.status(of: "%0") == initialStatus)
            #expect(await fixture.tmux.ask(of: "%0") == "4000 ask-dismiss")

            // Dismissing the card sends Escape, writes idle, and clears @heeler-ask.
            let dismissing = Task { await card.perform(.dismiss) }
            try await Fixture.waitUntil("Escape sent") {
                await fixture.sendWords().contains(["send-keys", "-t", "%0", "Escape"])
            }
            try await Fixture.setScreen(Self.readyScreen, on: fixture.tmux)
            await dismissing.value
            #expect(await fixture.tmux.status(of: "%0") == "state=idle:app=claude-code:turn=4:blocked=2")
            #expect(await fixture.tmux.ask(of: "%0") == "")
            fixture.finish()
        }

        // 2. Generic card on tmux: "Deny", "Don't allow", "Reject", and "No, skip" each write idle.
        let genericRows = Self.genericClaudeRows(
            title: "Which database?",
            options: [
                "Yes, allow once",
                "Allow once",
                "Postgres (Recommended)",
                "No, skip",
                "Deny",
                "Don't allow",
                "Reject",
                "Inspect details",
            ])
        let genericScreen = genericRows.joined(separator: "\n")
        for declineNumber in [4, 5, 6, 7] {
            let fixture = try await Fixture(state: "blocked", turn: 6, blocked: 2, screen: nil)
            await Fixture.setRawScreen(genericScreen, on: fixture.tmux)
            await fixture.tmux.setAsk("4000 ask-\(declineNumber)", of: "%0")
            let card = try await fixture.blockedCard()
            guard case .generic = card.content else {
                Issue.record("Expected generic card for option \(declineNumber), got \(card.content)")
                fixture.finish()
                return
            }

            let pressing = Task { await card.press(number: declineNumber) }
            try await Fixture.waitUntil("digit \(declineNumber) sent") {
                await fixture.sendWords().contains(["send-keys", "-l", "-t", "%0", "--", String(declineNumber)])
            }
            try await Fixture.setScreen(Self.readyScreen, on: fixture.tmux)
            await pressing.value

            #expect(
                await fixture.tmux.status(of: "%0") == "state=idle:app=claude-code:turn=6:blocked=2",
                "option \(declineNumber)")
            #expect(await fixture.tmux.ask(of: "%0") == "", "option \(declineNumber)")
            fixture.finish()
        }

        // 3. Generic card on tmux: "Yes, allow once", "Allow once", and a single-question match write working.
        let singleQuestion = ChatPendingRequest(
            entryID: ChatEntryID("q-db"), callID: "toolu_db", kind: .question, toolName: "AskUserQuestion",
            summary: "Which database?",
            questions: [ChatQuestion(text: "Which database?", options: ["Postgres", "SQLite"])])
        for answerNumber in [1, 2, 3] {
            let fixture = try await Fixture(state: "blocked", turn: 6, blocked: 2, screen: nil)
            await Fixture.setRawScreen(genericScreen, on: fixture.tmux)
            await fixture.tmux.setAsk("4000 ask-\(answerNumber)", of: "%0")
            let card = try await fixture.blockedCard()
            let entry = ChatEntry(
                id: singleQuestion.entryID, sourceOffset: 0,
                content: .tool(
                    ChatToolActivity(
                        kind: .question, name: "AskUserQuestion", title: "Which database?",
                        status: .awaitingApproval, callID: singleQuestion.callID)))
            card.update(transcript: ChatTranscript(entries: [entry], pendingRequests: [singleQuestion]))

            let pressing = Task { await card.press(number: answerNumber) }
            try await Fixture.waitUntil("digit \(answerNumber) sent") {
                await fixture.sendWords().contains(["send-keys", "-l", "-t", "%0", "--", String(answerNumber)])
            }
            try await Fixture.setScreen(Self.readyScreen, on: fixture.tmux)
            await pressing.value

            #expect(
                await fixture.tmux.status(of: "%0") == "state=working:app=claude-code:turn=6:blocked=2",
                "option \(answerNumber)")
            #expect(await fixture.tmux.ask(of: "%0") == "", "option \(answerNumber)")
            fixture.finish()
        }

        // 4. Generic card on tmux: unknown ordinal (99) and unrecognised label ("Inspect details", 8)
        // each write nothing at all to @heeler-status or @heeler-ask.
        do {
            let fixture = try await Fixture(state: "blocked", turn: 6, blocked: 2, screen: nil)
            await Fixture.setRawScreen(genericScreen, on: fixture.tmux)
            let initialStatus = try #require(await fixture.tmux.status(of: "%0"))
            await fixture.tmux.setAsk("4000 ask-unknown", of: "%0")
            let card = try await fixture.blockedCard()

            // Unknown number on generic card sends nothing and writes nothing.
            await card.press(number: 99)
            #expect(await fixture.sendWords().isEmpty)
            #expect(await fixture.tmux.status(of: "%0") == initialStatus)
            #expect(await fixture.tmux.ask(of: "%0") == "4000 ask-unknown")

            // Unrecognised label ("Inspect details", 8) sends "8" and writes NOTHING to status or ask.
            let pressing = Task { await card.press(number: 8) }
            try await Fixture.waitUntil("digit 8 sent") {
                await fixture.sendWords().contains(["send-keys", "-l", "-t", "%0", "--", "8"])
            }
            try await Fixture.setScreen(Self.readyScreen, on: fixture.tmux)
            await pressing.value

            #expect(await fixture.tmux.status(of: "%0") == initialStatus)
            #expect(await fixture.tmux.ask(of: "%0") == "4000 ask-unknown")
            #expect(await fixture.tmux.openControlClients == 0)
            fixture.finish()
        }
    }

    private static func genericClaudeRows(title: String, options: [String]) -> [String] {
        var rows = [
            SGR.claudeRule(108),
            " \(SGR.reset)\(SGR.bold)\(title)\(SGR.reset)",
            "",
        ]
        for (offset, label) in options.enumerated() {
            let number = offset + 1
            if offset == 0 {
                rows.append(
                    " \(SGR.reset)\(SGR.claudeAccent)❯ \(SGR.reset)\(SGR.claudeInactive)\(number). \(SGR.reset)\(SGR.claudeAccent)\(label)\(SGR.reset)")
            } else {
                rows.append("   \(SGR.reset)\(SGR.claudeInactive)\(number). \(SGR.reset)\(label)")
            }
        }
        rows.append("")
        rows.append(" \(SGR.reset)\(SGR.claudeInactive)Esc to cancel · Enter to confirm\(SGR.reset)")
        return rows
    }
}
