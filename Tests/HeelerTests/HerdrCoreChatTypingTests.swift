import Foundation
import Testing

@testable import Heeler

/// Chat's Send, Stop and Blocked answers on a core Host (ADR 0035), from the Composer
/// and the stores down: the real Console, Host session and link, with the core
/// scripted and its screens the paints a real core sent. What is asserted is what
/// reaches the core.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreChatTypingTests {
    /// Chat's rules send a message with one trailing space.
    private static let pasteOfSend = "\u{1B}[200~hello \u{1B}[201~"
    private static let paste = "\u{1B}[200~hello\u{1B}[201~"
    private static let enter = "\r"
    private static let ctrlC = "\u{3}"
    private static let esc = "\u{1B}"
    private static let bracketedPasteOn = "\u{1B}[?2004h"
    private static let kittyAllKeys = "\u{1B}[=8;1u"
    private static let readyScreen = "claude-01-ready"
    private static let dialogScreen = "claude-02-c1-bash-blocked"

    private typealias Attached = (channel: UInt32, params: JSONValue, socket: FakeCoreSocket)

    /// A captured paint, with the modes the program asked for where a core puts them.
    private static func paint(_ stem: String, modes: String = bracketedPasteOn) throws -> Data {
        let end = "\u{1B}[?9001l"
        let captured = try ChatFixture.text("screens/core-paint/\(stem).paint")
        return Data(captured.replacingOccurrences(of: end, with: modes + end).utf8)
    }

    /// A question Heeler can't name, so its card has only the key pad. No core paint
    /// of it was captured: this wraps the capture's rows in the end of a paint, which
    /// `HerdrCoreFirstPaintTests` shows reads as the capture does.
    private static func previewsPaint(
        asking question: String = "Which layout?", previewing preview: String = "header"
    ) throws -> Data {
        let captured = try ScreenFixture.text("claude-42-c8-phone-question-previews")
        let drawn =
            captured
            .replacingOccurrences(of: "Which layout?", with: question)
            .replacingOccurrences(of: "header", with: preview)
        return Data((drawn + "\u{1B}[1;1H\u{1B}[?9001l").utf8)
    }

    private static func foreground(pid: Int = 40, argv: [String] = ["claude"]) -> JSONValue {
        .object([
            "pid": .number(Double(pid)), "name": .string(argv.first ?? ""),
            "argv": .array(argv.map(JSONValue.string)), "cwd": .string("/work/app"),
        ])
    }

    private static func record(
        argv: [String] = ["claude"], status: String = "idle", app: String = "claude-code", submit: String? = nil,
        stop: String? = nil, columns: Int = 80, rows: Int = 24
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array(argv.map(JSONValue.string)), "keep": .bool(false), "title": .string(""),
            "cols": .number(Double(columns)), "rows": .number(Double(rows)), "pid": .number(7),
            "foreground": Self.foreground(argv: argv),
            "status": .object(["state": .string(status), "app": .string(app)]),
            "labels": .object([:]),
        ]
        fields["submit"] = submit.map(JSONValue.string)
        fields["stop"] = stop.map(JSONValue.string)
        return .object(fields)
    }

    private static func until(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    @MainActor
    private struct Fixture {
        let scripted: ScriptedCoreHost
        let console: ConsoleStore
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        let clock = ManualClock()
        let composer: AgentComposerStore
        let agent: ConsoleAgent

        init(
            terminal: JSONValue = HerdrCoreChatTypingTests.record(),
            screen: String = HerdrCoreChatTypingTests.readyScreen,
            modes: String = HerdrCoreChatTypingTests.bracketedPasteOn
        ) async throws {
            let scripted = ScriptedCoreHost(channel: .core(.init(id: "c1", terminals: [terminal])))
            self.scripted = scripted
            await scripted.setAttachPaint(try HerdrCoreChatTypingTests.paint(screen, modes: modes))
            let clock = clock
            let console = ConsoleStore(
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in
                    HerdrCoreHostSession(
                        connect: {
                            await scripted.setConnected(true)
                            return scripted.transport()
                        },
                        keepalive: nil)
                },
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-chat-typing-\(UUID().uuidString)") ?? .standard),
                coreSendClock: BlockedCardClock(now: clock.clock.now, sleep: clock.parkedSleep(for:)))
            self.console = console
            console.setHosts([host])
            await console.resume()
            try await until("the Agent") { [console] in !console.agents.isEmpty }
            let agent = try #require(console.agents.first)
            self.agent = agent
            composer = console.composerStore(for: agent)
            composer.open()
        }

        func finish() {
            console.setHosts([])
        }

        /// Chat's policy as its surface builds it, over the Console's screen reads,
        /// with the delivery check's pause already over.
        var policy: ComposerDeliveryPolicy {
            let console = console
            let hostID = host.id
            return .chat(
                rules: ChatSendRules(
                    program: .claude,
                    commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .claude)),
                activity: { .idle },
                readScreen: { try await console.readAgentScreen("t1", on: hostID) },
                pause: { _ in })
        }

        var viewers: [Attached] {
            get async { await scripted.attaches.filter { $0.params["resumed"] == .bool(true) } }
        }

        var reads: [Attached] {
            get async { await scripted.attaches.filter { $0.params["observe"] == .bool(true) } }
        }

        func viewer() async throws -> Attached {
            try await until("Chat's viewer") { await !viewers.isEmpty }
            return try #require(await viewers.first)
        }

        func written(on viewer: Attached) async -> [String] {
            await viewer.socket.dataWritten(channel: viewer.channel)
        }

        func startSend() -> Task<AgentComposerStore.SendResult, Never> {
            composer.replaceDraft(with: "hello")
            let composer = composer
            let policy = policy
            return Task { await composer.send(policy: policy) }
        }

        /// Starts a Send and returns once its paste has reached the core.
        func sendPastingHello() async throws -> (sending: Task<AgentComposerStore.SendResult, Never>, viewer: Attached) {
            let sending = startSend()
            let viewer = try await viewer()
            await viewer.socket.waitForData(channel: viewer.channel, count: 1)
            return (sending, viewer)
        }

        /// Takes the sample delay's 550 ms, with nothing else having happened.
        func passSampleDelay() async {
            await clock.untilParked(for: HerdrCoreComposerSend.sampleDelay)
            clock.advance(HerdrCoreComposerSend.sampleDelay)
        }

        /// The sample delay and the read that follows it, answered with `record`.
        func answerSample(with record: JSONValue = HerdrCoreChatTypingTests.record()) async {
            await passSampleDelay()
            await scripted.waitForMethod("terminal.get")
            await scripted.answerTerminalReads(with: record)
        }

        func deliverEvent(_ type: String, data: JSONValue, sequence: Int = 101) async throws {
            let line = try JSONEncoder().encode(
                JSONValue.object([
                    "jsonrpc": .string("2.0"), "method": .string("event"),
                    "params": .object([
                        "seq": .number(Double(sequence)), "type": .string(type), "terminal": .string("t1"),
                        "data": data,
                    ]),
                ]))
            let events = try #require(await scripted.sockets.first)
            try await scripted.deliverEvent(line, on: events)
        }

        /// Events apply in order, so a title showing means those before it applied.
        func untilEventsApplied() async throws {
            try await deliverEvent("title", data: .object(["title": .string("applied")]), sequence: 102)
            try await until("the events") { [console] in console.agents.first?.agent.terminalTitle == "applied" }
        }

        func deliverSize(columns: Int, rows: Int) async throws {
            try await deliverEvent(
                "size", data: .object(["cols": .number(Double(columns)), "rows": .number(Double(rows))]))
            try await untilEventsApplied()
        }

        // MARK: Stop

        func stop(as program: ChatProgram, activity: ChatAgentActivity = .working) async -> AgentInterruptOutcome {
            let console = console
            let hostID = host.id
            let keys = ChatAgentKeysStore { try await console.sendAgentKeys($0, to: "t1", on: hostID) }
            let interrupt = console.chatStopPlan(for: agent, program: program).composerInterrupt(
                context: {
                    ChatStopContext(screen: try await console.readAgentScreen("t1", on: hostID), activity: activity)
                },
                agentKeys: keys)
            return await interrupt.perform()
        }

        // MARK: Blocked

        /// The Blocked card of a Chat that has read `screen`, showing its dialog.
        func blockedCard() async throws -> BlockedCardStore {
            try await until("Chat") { [console, agent] in console.chatProgram(for: agent) != nil }
            let chat = try #require(console.chatStore(for: agent, program: .claude))
            chat.blocked.update(activity: .blocked)
            await chat.blocked.refresh()
            guard case .card = chat.blocked.content else {
                Issue.record("Expected a card, got \(chat.blocked.content)")
                return chat.blocked
            }
            return chat.blocked
        }

        /// An answer past its check of the screen, its viewer's attach not answered.
        func answerWaitingForItsViewer(on card: BlockedCardStore) async throws -> (Task<Void, Never>, Attached) {
            await scripted.holdAttachReplies(onlyViewers: true)
            let answering = Task { await card.perform(.choose(ordinal: 1)) }
            return (answering, try await viewer())
        }

        /// The card of a Chat that has read `paint`, whatever that shows.
        func keyPadCard(showing paint: Data) async throws -> BlockedCardStore {
            await scripted.setAttachPaint(paint)
            try await until("Chat") { [console, agent] in console.chatProgram(for: agent) != nil }
            let chat = try #require(console.chatStore(for: agent, program: .claude))
            chat.blocked.update(activity: .blocked)
            await chat.blocked.refresh()
            return chat.blocked
        }

        /// The card of a Chat whose Blocked Agent has shown no dialog for long enough.
        func unreadableCard() async throws -> BlockedCardStore {
            let card = try await keyPadCard(showing: try HerdrCoreChatTypingTests.paint(readyScreen, modes: ""))
            try await Task.sleep(for: BlockedCardStore.Timing().unreadableAfter)
            await card.refresh()
            #expect(card.content == .unreadable)
            return card
        }

        /// An Enter from the key pad, its viewer's attach not answered.
        func keyWaitingForItsViewer(on card: BlockedCardStore) async throws -> (Task<Void, Never>, Attached) {
            await scripted.holdAttachReplies(onlyViewers: true)
            let pressing = Task { await card.sendKeys(["enter"]) }
            return (pressing, try await viewer())
        }
    }

    private static func noAuthoredInputRPC(_ scripted: ScriptedCoreHost) async -> Bool {
        let methods = await scripted.methods
        return !methods.contains("terminal.send") && !methods.contains("terminal.keys")
    }

    // MARK: A detail whose core is gone

    private static let coreGone =
        "This Terminal belongs to a core that is gone: Nothing was sent. Open it again from the list."

    /// The core wiped, or another one under another state directory, with an Agent
    /// of its own at t1, under a detail opened on the last one.
    private func moveToAnotherCore(_ fixture: Fixture) async throws -> Int {
        await fixture.scripted.setChannel(.core(.init(id: "c2", terminals: [Self.record()])))
        let events = try #require(await fixture.scripted.sockets.first)
        await events.deliverEndOfFile()
        try await Self.until("the new core's snapshot") { [console = fixture.console, host = fixture.host] in
            console.hostCores[host.id] == "c2" && !console.agents.isEmpty
        }
        return await fixture.scripted.attaches.count
    }

    /// The surface's own read refuses first. Its Send refuses by itself as well, for
    /// a read that went by another way.
    @Test func aChatsSendTypesNothingOnceAnotherCoreServesTheAddress() async throws {
        let fixture = try await Fixture()
        let console = fixture.console
        let hostID = fixture.host.id
        let pin = console.composerSession(for: fixture.agent).corePin
        let attaches = try await moveToAnotherCore(fixture)
        let surfacePolicy = ComposerDeliveryPolicy.chat(
            rules: ChatSendRules(
                program: .claude,
                commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .claude)),
            activity: { .idle },
            readScreen: { try await console.readAgentScreen("t1", on: hostID, keepingTo: pin) },
            pause: { _ in })

        fixture.composer.replaceDraft(with: "hello")
        let refused = await fixture.composer.send(policy: surfacePolicy)

        #expect(
            refused
                == .refused(
                    .inputNotReady(
                        "Heeler couldn't check the Agent's input box. This Terminal belongs to a core that is gone: Nothing was sent."
                    )))
        #expect(fixture.composer.draft == "hello")
        #expect(await fixture.scripted.attaches.count == attaches)

        let readAnotherWay = await fixture.composer.send(policy: fixture.policy)

        #expect(readAnotherWay == .refused(.inputNotReady(Self.coreGone)))
        #expect(fixture.composer.draft == "hello")
        #expect(await fixture.viewers.isEmpty)
        fixture.finish()
    }

    @Test func aChatsStopAndKeysPressNothingOnceAnotherCoreServesTheAddress() async throws {
        let fixture = try await Fixture()
        let console = fixture.console
        let hostID = fixture.host.id
        let pin = console.composerSession(for: fixture.agent).corePin
        let keys = ChatAgentKeysStore { try await console.sendAgentKeys($0, to: "t1", on: hostID, keepingTo: pin) }
        let attaches = try await moveToAnotherCore(fixture)

        #expect(await keys.deliver(["esc"]) == .withheld(Self.coreGone))
        await #expect(throws: TransportError.herdrCoreTerminalGone) {
            _ = try await console.readAgentScreen("t1", on: hostID, keepingTo: pin)
        }
        let stop = console.chatStopPlan(for: fixture.agent, program: .claude).composerInterrupt(
            context: {
                ChatStopContext(
                    screen: try await console.readAgentScreen("t1", on: hostID, keepingTo: pin), activity: .working)
            },
            agentKeys: keys)
        guard case .failed = await stop.perform() else {
            Issue.record("A Stop went out from a detail whose core is gone")
            return
        }

        #expect(await fixture.scripted.attaches.count == attaches)
        fixture.finish()
    }

    /// The old core's Chat ended, so its card takes no answer. One already on its
    /// way by then has only the old store's way to the Agent left, which ends with
    /// that core, whatever now answers at the address.
    @Test func aBlockedAnswerTypesNothingOnceAnotherCoreServesTheAddress() async throws {
        let fixture = try await Fixture(screen: Self.dialogScreen)
        let card = try await fixture.blockedCard()
        let projection = try #require(fixture.console.coreProjection(on: fixture.host.id))
        let typing = projection.chatTyping(at: "t1")
        let screen = typing.blockedScreen
        let attaches = try await moveToAnotherCore(fixture)

        await card.perform(.choose(ordinal: 1))
        let refusal = HerdrCoreChatTyping.Refusal(message: Self.coreGone)
        await #expect(throws: refusal) { _ = try await screen.readScreen() }
        await #expect(throws: refusal) { try await screen.type(.keys(["1"]), whileShowing: { _ in true }) }
        await #expect(throws: refusal) { try await screen.type(.paste("note"), whileShowing: { _ in true }) }

        #expect(await fixture.scripted.attaches.count == attaches)
        #expect(await fixture.viewers.isEmpty)
        #expect(projection.chatTyping(at: "t1") !== typing)
        fixture.finish()
    }

    /// Chat goes on to the address's new Agent, and a detail stays with its own: it
    /// falls back to its terminal, which says the core is gone.
    @Test func aDetailOffersNoChatOnceAnotherCoreServesTheAddress() async throws {
        let fixture = try await Fixture()
        let console = fixture.console
        try await Self.until("Chat") { [agent = fixture.agent] in console.chatProgram(for: agent) != nil }
        let pin = console.composerSession(for: fixture.agent).corePin
        #expect(console.chatProgram(for: fixture.agent, keepingTo: pin) == .claude)

        _ = try await moveToAnotherCore(fixture)
        let row = try #require(console.agents.first)

        #expect(console.chatProgram(for: row, keepingTo: pin) == nil)
        #expect(console.chatProgram(for: row, keepingTo: console.corePin(on: fixture.host.id)) != nil)
        fixture.finish()
    }

    /// A Chat opened on the new core's row answers that core's dialog.
    @Test func theNewCoresChatStillTypes() async throws {
        let fixture = try await Fixture(screen: Self.dialogScreen)
        _ = try await fixture.blockedCard()
        _ = try await moveToAnotherCore(fixture)
        let row = try #require(fixture.console.agents.first)
        try await Self.until("the new core's Chat") { [console = fixture.console] in
            console.chatStore(for: row, program: .claude)?.coreScope
                == ChatCacheKey.coreScope(session: "", coreID: "c2")
        }
        let next = try #require(fixture.console.chatStore(for: row, program: .claude))
        next.blocked.update(activity: .blocked)
        await next.blocked.refresh()
        guard case .card = next.blocked.content else {
            Issue.record("Expected a card, got \(next.blocked.content)")
            return
        }

        let answering = Task { await next.blocked.perform(.choose(ordinal: 1)) }

        let viewer = try await fixture.viewer()
        await viewer.socket.waitForData(channel: viewer.channel, count: 1)
        answering.cancel()
        fixture.finish()
    }

    // MARK: Chat's attach

    @Test func chatsAttachIsAResumedViewerOnTheHostsLinkThatReportsNoFacts() async throws {
        let fixture = try await Fixture()

        let (sending, viewer) = try await fixture.sendPastingHello()

        #expect(viewer.params["resumed"] == .bool(true))
        #expect(viewer.params["observe"] == nil)
        #expect(viewer.params["display"] == nil)
        #expect(viewer.params["history"] == nil)
        #expect(await fixture.scripted.sockets.count == 1)
        #expect(await fixture.scripted.sockets.first === viewer.socket)
        await fixture.answerSample()
        #expect(await sending.value == .submittedViaAttach)
        #expect(await viewer.socket.frames(channel: viewer.channel, kind: .facts).isEmpty)
        #expect(await viewer.socket.frames(channel: viewer.channel, kind: .focus).isEmpty)
        fixture.finish()
    }

    @Test func aResizeWithTheTerminalsLatestSizeGoesBeforeTheFirstData() async throws {
        let fixture = try await Fixture()
        try await fixture.deliverSize(columns: 100, rows: 30)

        let (sending, viewer) = try await fixture.sendPastingHello()

        let frames = await viewer.socket.writtenFrames.filter {
            $0.channel == viewer.channel && ($0.kind == .resize || $0.kind == .data)
        }
        #expect(frames.map(\.kind) == [.resize, .data])
        #expect(frames.first?.payload == Data([100, 0, 30, 0]))
        await fixture.answerSample(with: Self.record(columns: 100, rows: 30))
        #expect(await sending.value == .submittedViaAttach)
        fixture.finish()
    }

    /// Another viewer resized the Terminal while the Send waited for its sample.
    @Test func aSizeThatChangedBetweenItsStepsGoesBeforeTheNextOne() async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await fixture.sendPastingHello()

        try await fixture.deliverSize(columns: 90, rows: 20)
        await fixture.answerSample(with: Self.record(columns: 90, rows: 20))

        #expect(await sending.value == .submittedViaAttach)
        let frames = await viewer.socket.writtenFrames.filter {
            $0.channel == viewer.channel && ($0.kind == .resize || $0.kind == .data)
        }
        #expect(frames.map(\.kind) == [.resize, .data, .resize, .data])
        #expect(frames[safe: 0]?.payload == Data([80, 0, 24, 0]))
        #expect(frames[safe: 2]?.payload == Data([90, 0, 20, 0]))
        fixture.finish()
    }

    /// Past its one action, it no longer counts as a viewer of the Terminal.
    @Test func chatsViewerLeavesOnceItsSendIsOver() async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await fixture.sendPastingHello()
        #expect(await viewer.socket.frames(channel: viewer.channel, kind: .close).isEmpty)

        await fixture.answerSample()
        #expect(await sending.value == .submittedViaAttach)

        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        fixture.finish()
    }

    // MARK: Reading the screen

    @Test func aScreenReadObservesAndLeavesOnceItIsPainted() async throws {
        let fixture = try await Fixture(screen: Self.dialogScreen)

        let screen = try await fixture.console.readAgentScreen("t1", on: fixture.host.id)

        let original = ANSIScreenDecoder.decode(try ScreenFixture.text(Self.dialogScreen))
        #expect(screen.rows.map(\.trimmedText) == original.rows.map(\.trimmedText))
        let read = try #require(await fixture.reads.first)
        #expect(read.params["display"] == nil)
        #expect(await fixture.scripted.sockets.count == 1)
        _ = await read.socket.waitForFrame(channel: read.channel, kind: .close)
        #expect(await read.socket.frames(channel: read.channel, kind: .resize).isEmpty)
        #expect(await read.socket.dataWritten(channel: read.channel).isEmpty)
        fixture.finish()
    }

    /// The input box is what clears a Send, so with no screen nothing goes.
    @Test func aScreenThatNeverPaintsKeepsTheDraftAndSendsNothing() async throws {
        let fixture = try await Fixture()
        await fixture.scripted.setAttachPaint(nil)

        let sending = fixture.startSend()
        await fixture.scripted.waitForMethod("terminal.attach")
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)

        guard case .refused(.inputNotReady(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("couldn't check the Agent's input box"))
        #expect(fixture.composer.draft == "hello")
        #expect(await fixture.viewers.isEmpty)
        fixture.finish()
    }

    @Test func anInputBoxHoldingADraftKeepsTheDraftAndSendsNothing() async throws {
        let fixture = try await Fixture(screen: Self.dialogScreen)

        guard case .refused = await fixture.startSend().value else {
            Issue.record("Expected a refusal")
            return
        }

        #expect(fixture.composer.draft == "hello")
        #expect(await fixture.viewers.isEmpty)
        fixture.finish()
    }

    // MARK: Send

    @Test func aSampleOfTheSameProgramSubmitsWithEnter() async throws {
        let fixture = try await Fixture()

        let (sending, viewer) = try await fixture.sendPastingHello()
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend])
        #expect(await !fixture.scripted.methods.contains("terminal.get"))

        await fixture.answerSample()

        #expect(await sending.value == .submittedViaAttach)
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend, Self.enter])
        #expect(fixture.composer.draft.isEmpty)
        #expect(fixture.composer.notice == nil)
        #expect(await Self.noAuthoredInputRPC(fixture.scripted))
        fixture.finish()
    }

    @Test func aProgramThatAskedForEveryKeyGetsItsSubmitInThatForm() async throws {
        let fixture = try await Fixture(modes: Self.bracketedPasteOn + Self.kittyAllKeys)

        let (sending, viewer) = try await fixture.sendPastingHello()
        await fixture.answerSample()

        #expect(await sending.value == .submittedViaAttach)
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend, "\u{1B}[13u"])
        fixture.finish()
    }

    @Test func aTemplatesSubmitKeyIsWhatItPresses() async throws {
        let terminal = Self.record(submit: "ctrl+s")
        let fixture = try await Fixture(terminal: terminal)

        let (sending, viewer) = try await fixture.sendPastingHello()
        await fixture.answerSample(with: terminal)

        #expect(await sending.value == .submittedViaAttach)
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend, "\u{13}"])
        fixture.finish()
    }

    @Test func aChangedPidSubmitsNothingAndSaysTheTextMayRemain() async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await fixture.sendPastingHello()

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41))

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("may still be in the terminal"))
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend])
        #expect(fixture.composer.draft == "hello")
        fixture.finish()
    }

    @Test func aLateSampleSubmitsNothingAndSaysTheTextStayed() async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await fixture.sendPastingHello()
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")

        fixture.clock.advance(HerdrCoreComposerSend.submitWindow - HerdrCoreComposerSend.sampleDelay)
        await fixture.scripted.answerTerminalReads(with: Self.record())

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("stayed in the Agent's input unsubmitted"))
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend])
        #expect(fixture.composer.draft == "hello")
        fixture.finish()
    }

    @Test(arguments: [
        ("bash", "no longer in the terminal"), ("fish", "no longer in the terminal"),
        ("zsh", "may still be in the terminal"), ("nu", "may still be in the terminal"),
    ])
    func aShellInTheForegroundGetsOneCtrlC(shell: String, says copy: String) async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await fixture.sendPastingHello()

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41, argv: [shell]))

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains(copy), "\(reason)")
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend, Self.ctrlC])
        #expect(fixture.composer.draft == "hello")
        fixture.finish()
    }

    /// An Agent that died leaves its keyboard flags behind, and a shell reads no
    /// `CSI 99;5u`.
    @Test func theShellsCtrlCIsTheByteEvenWhereTheProgramAskedForEveryKey() async throws {
        let fixture = try await Fixture(modes: Self.bracketedPasteOn + Self.kittyAllKeys)
        let (sending, viewer) = try await fixture.sendPastingHello()

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41, argv: ["bash"]))

        _ = await sending.value
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend, Self.ctrlC])
        fixture.finish()
    }

    @Test func aBlockedAgentGetsNothingTyped() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"))

        #expect(await fixture.startSend().value == .refused(.agentBlocked))

        #expect(fixture.composer.draft == "hello")
        #expect(await fixture.viewers.isEmpty)
        fixture.finish()
    }

    @Test func anAgentThatStartedAskingBeforeTheSubmitGetsNoSubmit() async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await fixture.sendPastingHello()

        await fixture.answerSample(with: Self.record(status: "blocked"))

        guard case .refused(.notSubmitted(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("may still be in the Agent's input"))
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend])
        #expect(fixture.composer.draft == "hello")
        fixture.finish()
    }

    @Test func aProgramNotTakingAPasteGetsNothingTyped() async throws {
        let fixture = try await Fixture(modes: "")

        #expect(await fixture.startSend().value == .refused(.programNotAcceptingPaste))

        let viewer = try await fixture.viewer()
        #expect(await fixture.written(on: viewer).isEmpty)
        #expect(fixture.composer.draft == "hello")
        fixture.finish()
    }

    // MARK: A Send's viewer takes seconds to open

    /// A Send past its checks, its viewer's attach not answered.
    private static func sendWaitingForItsViewer(
        _ fixture: Fixture
    ) async throws -> (sending: Task<AgentComposerStore.SendResult, Never>, viewer: Attached) {
        await fixture.scripted.holdAttachReplies(onlyViewers: true)
        let sending = fixture.startSend()
        return (sending, try await fixture.viewer())
    }

    /// Nothing reached the program, the draft is back, and the viewer went.
    private static func expectNothingTyped(on viewer: Attached, _ fixture: Fixture) async {
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty)
        #expect(fixture.composer.draft == "hello")
        #expect(fixture.composer.messages.isEmpty)
    }

    @Test(arguments: [(41, "bash"), (40, "bash"), (40, "vim")])
    func aSendTypesNothingOnceTheAgentLeavesWhileItsViewerOpens(pid: Int, program: String) async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await Self.sendWaitingForItsViewer(fixture)

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: pid, argv: [program]))
        try await Self.until("the Agent to go") { fixture.console.agents.isEmpty }
        await fixture.scripted.releaseAttachReplies()

        guard case .refused(.inputNotReady(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("no longer holds this terminal"))
        await Self.expectNothingTyped(on: viewer, fixture)
        fixture.finish()
    }

    @Test func aSendTypesNothingOnAnotherProcessThatTookOverWhileItsViewerOpened() async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await Self.sendWaitingForItsViewer(fixture)

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41))
        try await fixture.untilEventsApplied()
        await fixture.scripted.releaseAttachReplies()

        guard case .refused(.inputNotReady(let reason)) = await sending.value else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(reason.contains("Another process took over"))
        await Self.expectNothingTyped(on: viewer, fixture)
        fixture.finish()
    }

    /// Chat answers a dialog with its card, and never types into one.
    @Test func aSendTypesNothingIntoADialogThatCameUpWhileItsViewerOpened() async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await Self.sendWaitingForItsViewer(fixture)

        try await fixture.deliverEvent(
            "status",
            data: .object([
                "status": .object(["state": .string("blocked"), "app": .string("claude-code")]),
                "reported": .bool(true),
            ]))
        try await fixture.untilEventsApplied()
        await fixture.scripted.releaseAttachReplies()

        #expect(await sending.value == .refused(.agentBlocked))
        await Self.expectNothingTyped(on: viewer, fixture)
        fixture.finish()
    }

    /// The other side of those: an open with nothing changed still sends.
    @Test func aSendGoesOnceItsViewerOpensOnTheSameProgram() async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await Self.sendWaitingForItsViewer(fixture)

        await fixture.scripted.releaseAttachReplies()
        await viewer.socket.waitForData(channel: viewer.channel, count: 1)
        await fixture.answerSample()

        #expect(await sending.value == .submittedViaAttach)
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend, Self.enter])
        fixture.finish()
    }

    // MARK: A step with no answer

    private static func expectUnknownAndNoRetry(_ fixture: Fixture) async throws {
        let message = try #require(fixture.composer.messages.last)
        #expect(message.state == .outcomeUnknown)
        #expect(fixture.composer.draft.isEmpty)
        #expect(await fixture.composer.retry(message.id, policy: fixture.policy) == .ignored)
        #expect(fixture.composer.messages.last?.state == .outcomeUnknown)
    }

    @Test func aPasteWithNoAnswerIsNeverSentAgain() async throws {
        let fixture = try await Fixture()
        let paint = try Self.paint(Self.readyScreen)
        await fixture.scripted.setAttachPaint(paint, viewers: false)

        let sending = fixture.startSend()
        let viewer = try await fixture.viewer()
        await viewer.socket.holdWrites()
        // A second on, so the viewer's own deadline is told apart from the paste's.
        fixture.clock.advance(.seconds(1))
        try await viewer.socket.deliver(HerdrCoreFrame(channel: viewer.channel, kind: .data, payload: paint))
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        await viewer.socket.waitForHeldWrite()
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)

        #expect(await sending.value == .outcomeUnknown)
        try await Self.expectUnknownAndNoRetry(fixture)

        // What was held reaches the core at most once, and the viewer goes.
        await viewer.socket.releaseWrites()
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).count <= 1)
        #expect(await fixture.viewers.count == 1)
        fixture.finish()
    }

    /// The outcome is unknown, so its echo says neither that it was sent nor that
    /// it was not, and the Transcript recording it settles the question.
    @Test func aChatSendWithNoAnswerEchoesAsUnknownUntilTheTranscriptRecordsIt() async throws {
        let fixture = try await Fixture()
        let (sending, _) = try await fixture.sendPastingHello()
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)
        #expect(await sending.value == .outcomeUnknown)

        let composer = fixture.composer
        let id = try #require(composer.messages.last?.id)
        let rules = ChatSendRules(program: .claude, commands: [])
        #expect(ChatComposerEchoes.sentMessages(composer.messages, rules: rules).map(\.isDelivered) == [true])
        #expect(ChatComposerEchoes.sentMessages(composer.messages, rules: rules).map(\.mayNotHaveGone) == [true])
        for status in [nil, AgentChatStore.SendStatus.awaiting, .overdue] {
            let statuses = status.map { [id: $0] } ?? [:]
            #expect(ChatComposerEchoes.pending(composer.messages, statuses: statuses).map(\.state) == [.outcomeUnknown])
        }
        #expect(ChatComposerEchoes.pending(composer.messages, statuses: [id: .recorded]).isEmpty)

        composer.settleUnknownOutcomes(recorded: [UUID()])
        #expect(composer.messages.last?.state == .outcomeUnknown)

        composer.settleUnknownOutcomes(recorded: [id])
        #expect(composer.messages.last?.state == .delivered(.acknowledged))
        composer.withdrawToDraft(id)
        #expect(composer.draft.isEmpty)
        #expect(composer.messages.last?.id == id)
        fixture.finish()
    }

    @Test func aSampleWithNoAnswerSubmitsNothingAndIsNeverSentAgain() async throws {
        let fixture = try await Fixture()
        let (sending, viewer) = try await fixture.sendPastingHello()
        await fixture.passSampleDelay()
        await fixture.scripted.waitForMethod("terminal.get")

        await fixture.clock.untilParked(for: HerdrCoreComposerSend.stepTimeout)
        fixture.clock.advance(HerdrCoreComposerSend.stepTimeout)

        #expect(await sending.value == .outcomeUnknown)
        try await Self.expectUnknownAndNoRetry(fixture)
        #expect(await fixture.written(on: viewer) == [Self.pasteOfSend])
        #expect(await fixture.viewers.count == 1)
        fixture.finish()
    }

    // MARK: Stop

    @Test(arguments: [
        (ChatProgram.claude, ["claude"], "claude-code"), (.codex, ["codex"], "codex"), (.pi, ["pi"], "pi"),
        (.omp, ["omp"], "omp"),
    ])
    func stopPressesEscWhereTheProgramStopsOnIt(program: ChatProgram, argv: [String], app: String) async throws {
        let fixture = try await Fixture(terminal: Self.record(argv: argv, app: app), modes: "")

        #expect(await fixture.stop(as: program) == .sent)

        let viewer = try await fixture.viewer()
        #expect(await fixture.written(on: viewer) == [Self.esc])
        #expect(await fixture.reads.isEmpty)
        fixture.finish()
    }

    @Test func stopPressesEscInTheFormTheProgramAskedFor() async throws {
        let fixture = try await Fixture(modes: Self.kittyAllKeys)

        #expect(await fixture.stop(as: .claude) == .sent)

        let viewer = try await fixture.viewer()
        #expect(await fixture.written(on: viewer) == ["\u{1B}[27u"])
        fixture.finish()
    }

    @Test func openCodesStopPressesEscTwiceInOneWriteOnARunningTurn() async throws {
        let fixture = try await Fixture(
            terminal: Self.record(argv: ["opencode"], app: "opencode"), screen: "opencode-08-working-180", modes: "")

        #expect(await fixture.stop(as: .opencode) == .sent)

        let viewer = try await fixture.viewer()
        #expect(await fixture.written(on: viewer) == [Self.esc + Self.esc])
        fixture.finish()
    }

    @Test func openCodesStopPressesNothingOverItsPermission() async throws {
        let fixture = try await Fixture(
            terminal: Self.record(argv: ["opencode"], app: "opencode"), screen: "opencode-10-permission-180")

        guard case .failed = await fixture.stop(as: .opencode) else {
            Issue.record("Expected Stop to press nothing")
            return
        }

        #expect(await fixture.viewers.isEmpty)
        fixture.finish()
    }

    @Test func grokBuildsStopPressesCtrlCOnARunningTurn() async throws {
        let fixture = try await Fixture(
            terminal: Self.record(argv: ["grok"], app: "grok"), screen: "grok-03-working", modes: "")

        #expect(await fixture.stop(as: .grok) == .sent)

        let viewer = try await fixture.viewer()
        #expect(await fixture.written(on: viewer) == [Self.ctrlC])
        fixture.finish()
    }

    @Test func grokBuildsStopPressesNothingOverItsPermission() async throws {
        let fixture = try await Fixture(
            terminal: Self.record(argv: ["grok"], app: "grok"), screen: "grok-12-permission-command")

        guard case .failed = await fixture.stop(as: .grok) else {
            Issue.record("Expected Stop to press nothing")
            return
        }

        #expect(await fixture.viewers.isEmpty)
        fixture.finish()
    }

    @Test func stopOnATemplatesTerminalPressesItsStopKey() async throws {
        let fixture = try await Fixture(terminal: Self.record(stop: "ctrl+g"), modes: "")

        #expect(await fixture.stop(as: .claude) == .sent)

        let viewer = try await fixture.viewer()
        #expect(await fixture.written(on: viewer) == ["\u{7}"])
        fixture.finish()
    }

    @Test func stopPressesNothingOnceTheAgentHasLeft() async throws {
        let fixture = try await Fixture()
        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41, argv: ["bash"]))
        try await Self.until("the Agent to go") { fixture.console.agents.isEmpty }

        guard case .failed(let reason) = await fixture.stop(as: .claude) else {
            Issue.record("Expected Stop to press nothing")
            return
        }

        #expect(reason.contains("no longer holds this terminal"))
        #expect(await fixture.viewers.isEmpty)
        fixture.finish()
    }

    // MARK: Blocked

    @Test func anAnswerGoesWhileItsDialogIsOnScreenAndTheAgentHoldsTheForeground() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: Self.dialogScreen, modes: "")
        let card = try await fixture.blockedCard()

        let answering = Task { await card.perform(.choose(ordinal: 1)) }
        let viewer = try await fixture.viewer()
        await viewer.socket.waitForData(channel: viewer.channel, count: 1)
        await fixture.scripted.setAttachPaint(try Self.paint(Self.readyScreen))
        await answering.value

        #expect(await fixture.written(on: viewer) == ["1"])
        #expect(card.notice == nil)
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        fixture.finish()
    }

    @Test func aChangedDialogGetsNoAnswer() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: "claude-30-par-first")
        let card = try await fixture.blockedCard()
        await fixture.scripted.setAttachPaint(try Self.paint("claude-31-par-second"))

        await card.perform(.choose(ordinal: 1))

        #expect(card.notice == "This prompt changed. Check it before answering.")
        #expect(await fixture.viewers.isEmpty)
        fixture.finish()
    }

    @Test func aShellInTheForegroundGetsNoAnswerWithTheDialogStillOnScreen() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: Self.dialogScreen)
        let card = try await fixture.blockedCard()
        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41, argv: ["bash"]))
        try await Self.until("the Agent to go") { fixture.console.agents.isEmpty }
        // The card has not heard yet, with the Agent's dialog still drawn.
        card.update(activity: .blocked)
        await card.refresh()

        await card.perform(.choose(ordinal: 1))

        #expect(card.notice?.contains("no longer holds this terminal") == true, "\(card.notice ?? "")")
        #expect(await fixture.viewers.isEmpty)
        fixture.finish()
    }

    /// The same dialog from another process may not be the one the user read.
    @Test func anotherProcessGetsNoAnswerUntilItsScreenHasBeenReadAgain() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: Self.dialogScreen, modes: "")
        let card = try await fixture.blockedCard()
        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41))
        try await fixture.untilEventsApplied()

        await card.perform(.choose(ordinal: 1))

        #expect(card.notice?.contains("Another process took over") == true, "\(card.notice ?? "")")
        #expect(await fixture.viewers.isEmpty)

        // The next read has seen only that process, so its dialog can be answered.
        await card.refresh()
        let answering = Task { await card.perform(.choose(ordinal: 1)) }
        let viewer = try await fixture.viewer()
        await viewer.socket.waitForData(channel: viewer.channel, count: 1)
        await fixture.scripted.setAttachPaint(try Self.paint(Self.readyScreen))
        await answering.value
        #expect(await fixture.written(on: viewer) == ["1"])
        fixture.finish()
    }

    // MARK: While an answer's viewer opens

    /// Opening a viewer can take seconds, and each of these changes during it.
    @Test func anAnswerGoesOnceItsViewerOpensOnTheSameDialog() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: Self.dialogScreen, modes: "")
        let card = try await fixture.blockedCard()
        let (answering, viewer) = try await fixture.answerWaitingForItsViewer(on: card)

        await fixture.scripted.releaseAttachReplies()
        await viewer.socket.waitForData(channel: viewer.channel, count: 1)
        await fixture.scripted.setAttachPaint(try Self.paint(Self.readyScreen))
        await answering.value

        #expect(await fixture.written(on: viewer) == ["1"])
        #expect(card.notice == nil)
        fixture.finish()
    }

    @Test func aShellTakingTheForegroundWhileAnAnswersViewerOpensGetsNoAnswer() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: Self.dialogScreen, modes: "")
        let card = try await fixture.blockedCard()
        let (answering, viewer) = try await fixture.answerWaitingForItsViewer(on: card)

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41, argv: ["bash"]))
        try await Self.until("the Agent to go") { fixture.console.agents.isEmpty }
        await fixture.scripted.releaseAttachReplies()
        await answering.value

        #expect(card.notice?.contains("no longer holds this terminal") == true, "\(card.notice ?? "")")
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    /// Another pid, or another program behind the pid a wrapper keeps.
    @Test(arguments: [(41, ["claude"]), (40, ["codex"])])
    func anotherProcessTakingTheForegroundWhileAnAnswersViewerOpensGetsNoAnswer(pid: Int, argv: [String]) async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: Self.dialogScreen, modes: "")
        let card = try await fixture.blockedCard()
        let (answering, viewer) = try await fixture.answerWaitingForItsViewer(on: card)

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: pid, argv: argv))
        try await fixture.untilEventsApplied()
        await fixture.scripted.releaseAttachReplies()
        await answering.value

        #expect(card.notice?.contains("Another process took over") == true, "\(card.notice ?? "")")
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    /// The attach has its answer, and the paint is still on its way.
    @Test func anotherProcessTakingTheForegroundBeforeAViewersPaintGetsNoAnswer() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: Self.dialogScreen, modes: "")
        let card = try await fixture.blockedCard()
        let paint = try Self.paint(Self.dialogScreen, modes: "")
        await fixture.scripted.setAttachPaint(paint, viewers: false)
        let answering = Task { await card.perform(.choose(ordinal: 1)) }
        let viewer = try await fixture.viewer()

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41))
        try await fixture.untilEventsApplied()
        try await viewer.socket.deliver(HerdrCoreFrame(channel: viewer.channel, kind: .data, payload: paint))
        await answering.value

        #expect(card.notice?.contains("Another process took over") == true, "\(card.notice ?? "")")
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    /// Another client answered it, or the next dialog took its place. The viewer's
    /// paint is the newest screen there is, so that is what the answer goes by.
    @Test(arguments: ["claude-01-ready", "claude-31-par-second"])
    func aDialogThatChangedWhileAnAnswersViewerOpenedGetsNoAnswer(now: String) async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), screen: "claude-30-par-first", modes: "")
        let card = try await fixture.blockedCard()
        let (answering, viewer) = try await fixture.answerWaitingForItsViewer(on: card)

        await fixture.scripted.setAttachPaint(try Self.paint(now, modes: ""))
        await fixture.scripted.releaseAttachReplies()
        await answering.value

        #expect(card.notice == "This prompt changed. Check it before answering.")
        #expect(card.progress == .ready)
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    /// A note goes in as a paste and an Enter, each opening a viewer of its own.
    @Test func everyStepOfAnAnswerGoesOnlyOverTheDialogItAnswers() async throws {
        let note = "Do not create it; reply with the single word skipped"
        let pane = NoteDialogPane(
            showing: try ScreenFixture.screen("claude-04-c1-tab-on-no"),
            afterPaste: try ScreenFixture.screen("claude-05-c1-pasted-feedback"),
            afterEnter: try ScreenFixture.screen(Self.readyScreen),
            anotherDialog: try ScreenFixture.screen("claude-31-par-second"))
        let card = BlockedCardStore(
            program: .claude,
            io: BlockedScreenIO(
                readScreen: { await pane.screen },
                sendKeys: { _ in Issue.record("A step went with no check of the screen") },
                paste: { _ in Issue.record("A step went with no check of the screen") },
                typeWhileShowing: { await pane.type($0, whileShowing: $1) }),
            clock: ManualClock().clock)
        card.update(activity: .blocked)
        await card.refresh()

        await card.perform(.amend(ordinal: 4, note: note))

        #expect(await pane.typed == ["paste \(note)", "keys enter"])
        #expect(await pane.answersOnItsDialog == [true, true])
        #expect(await pane.answersOnAnotherDialog == [false, false])
    }

    @Test func stopPressesNothingOnceTheAgentLeavesWhileItsViewerOpens() async throws {
        let fixture = try await Fixture()
        await fixture.scripted.holdAttachReplies(onlyViewers: true)
        let stopping = Task { await fixture.stop(as: .claude) }
        let viewer = try await fixture.viewer()

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41, argv: ["bash"]))
        try await Self.until("the Agent to go") { fixture.console.agents.isEmpty }
        await fixture.scripted.releaseAttachReplies()

        guard case .failed(let reason) = await stopping.value else {
            Issue.record("Expected Stop to press nothing")
            return
        }
        #expect(reason.contains("no longer holds this terminal"))
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    /// The turn Stop was tapped for was the other process's.
    @Test func stopPressesNothingOnAnotherProcessThatTookOverWhileItsViewerOpened() async throws {
        let fixture = try await Fixture()
        await fixture.scripted.holdAttachReplies(onlyViewers: true)
        let stopping = Task { await fixture.stop(as: .claude) }
        let viewer = try await fixture.viewer()

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41))
        try await fixture.untilEventsApplied()
        await fixture.scripted.releaseAttachReplies()

        guard case .failed(let reason) = await stopping.value else {
            Issue.record("Expected Stop to press nothing")
            return
        }
        #expect(reason.contains("Another process took over"))
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    @Test func aPasteGoesNowhereOnceTheAgentLeavesWhileItsViewerOpens() async throws {
        let fixture = try await Fixture()
        await fixture.scripted.holdAttachReplies(onlyViewers: true)
        let console = fixture.console
        let hostID = fixture.host.id
        let pasting = Task { try await console.pasteIntoAgent("hello", paneID: "t1", on: hostID) }
        let viewer = try await fixture.viewer()

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41, argv: ["bash"]))
        try await Self.until("the Agent to go") { fixture.console.agents.isEmpty }
        await fixture.scripted.releaseAttachReplies()

        await #expect(throws: HerdrCoreChatTyping.Refusal.self) { try await pasting.value }
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    // MARK: The key pad

    /// Where a card has no options to press, its key pad is how the dialog gets
    /// answered, so an Enter here takes whatever the dialog has as its default.
    @Test func aKeyPadKeyGoesOnceItsViewerOpensOnTheSameDialog() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.keyPadCard(showing: try Self.previewsPaint())
        let (pressing, viewer) = try await fixture.keyWaitingForItsViewer(on: card)

        await fixture.scripted.releaseAttachReplies()
        await pressing.value

        #expect(await fixture.written(on: viewer) == [Self.enter])
        #expect(card.notice == nil)
        #expect(card.progress == .ready)
        fixture.finish()
    }

    /// Another client answered it, and the same Agent shows the next dialog, one
    /// of those Heeler can't name.
    @Test func aKeyPadKeyPressesNothingOnAnotherGenericDialog() async throws {
        let next = try Self.previewsPaint(asking: "Which theme?")
        try await Self.expectKeyPadPressesNothing(onceThePaintIs: next)
    }

    /// The next dialog is one Heeler can name, or there is none any more.
    @Test(arguments: ["claude-31-par-second", "claude-01-ready"])
    func aKeyPadKeyPressesNothingOnAScreenThatChangedWhileItsViewerOpened(now: String) async throws {
        try await Self.expectKeyPadPressesNothing(onceThePaintIs: try Self.paint(now, modes: ""))
    }

    /// A dialog that stopped part way shows on the generic card by its own
    /// fingerprint, and a tap can land just as a known dialog's card replaces the
    /// generic one, so the key pad goes by a known dialog too.
    @Test func aKeyPadKeyPressesNothingOverACardWhoseDialogChanged() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.keyPadCard(showing: try Self.paint("claude-30-par-first", modes: ""))
        let (pressing, viewer) = try await fixture.keyWaitingForItsViewer(on: card)

        await fixture.scripted.setAttachPaint(try Self.paint("claude-31-par-second", modes: ""))
        await fixture.scripted.releaseAttachReplies()
        await pressing.value

        #expect(card.notice == BlockedCardStore.changedMessage)
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    @Test func aKeyPadKeyPressesNothingOnceTheAgentLeavesWhileItsViewerOpens() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.keyPadCard(showing: try Self.previewsPaint())
        let (pressing, viewer) = try await fixture.keyWaitingForItsViewer(on: card)

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41, argv: ["bash"]))
        try await Self.until("the Agent to go") { fixture.console.agents.isEmpty }
        await fixture.scripted.releaseAttachReplies()
        await pressing.value

        #expect(card.notice?.contains("no longer holds this terminal") == true, "\(card.notice ?? "")")
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    /// Another pid, or another program behind the pid a wrapper keeps.
    @Test(arguments: [(41, ["claude"]), (40, ["codex"])])
    func aKeyPadKeyPressesNothingOnAnotherProcessThatTookOverWhileItsViewerOpened(pid: Int, argv: [String]) async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.keyPadCard(showing: try Self.previewsPaint())
        let (pressing, viewer) = try await fixture.keyWaitingForItsViewer(on: card)

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: pid, argv: argv))
        try await fixture.untilEventsApplied()
        await fixture.scripted.releaseAttachReplies()
        await pressing.value

        #expect(card.notice?.contains("Another process took over") == true, "\(card.notice ?? "")")
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    /// The read after a key redraws the card, and must not take the reason with it.
    @Test func aKeyPadKeySaysWhyItPressedNothingOnceTheDialogHasGoneToo() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.keyPadCard(showing: try Self.previewsPaint())
        let (pressing, viewer) = try await fixture.keyWaitingForItsViewer(on: card)

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41))
        try await fixture.untilEventsApplied()
        await fixture.scripted.setAttachPaint(try Self.paint(Self.readyScreen, modes: ""))
        await fixture.scripted.releaseAttachReplies()
        await pressing.value

        #expect(card.notice?.contains("Another process took over") == true, "\(card.notice ?? "")")
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    /// Moving through a dialog can change what it shows, as a preview beside its
    /// options does. The read after each key is what the next key goes by.
    @Test func theKeyPadKeepsMovingThroughADialogItsKeysChange() async throws {
        let moved = try Self.previewsPaint(previewing: "footer")
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.keyPadCard(showing: try Self.previewsPaint())

        let moving = Task { await card.sendKeys(["down"]) }
        let first = try await fixture.viewer()
        await first.socket.waitForData(channel: first.channel, count: 1)
        await fixture.scripted.setAttachPaint(moved)
        await moving.value
        #expect(await fixture.written(on: first) == ["\u{1B}[B"])
        #expect(card.notice == nil)

        await card.sendKeys(["enter"])

        let viewers = await fixture.viewers
        #expect(viewers.count == 2)
        let second = try #require(viewers.last)
        #expect(await fixture.written(on: second) == [Self.enter])
        #expect(card.notice == nil)
        fixture.finish()
    }

    @Test func anUnreadableCardsKeyGoesWhileItsScreenStillShowsNoDialog() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.unreadableCard()
        let (pressing, viewer) = try await fixture.keyWaitingForItsViewer(on: card)

        await fixture.scripted.releaseAttachReplies()
        await pressing.value

        #expect(await fixture.written(on: viewer) == [Self.enter])
        #expect(card.notice == nil)
        fixture.finish()
    }

    /// A card with nothing to read has still told the user there is no dialog.
    @Test func anUnreadableCardsKeyPressesNothingOnADialogDrawnWhileItsViewerOpened() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.unreadableCard()
        let (pressing, viewer) = try await fixture.keyWaitingForItsViewer(on: card)

        await fixture.scripted.setAttachPaint(try Self.paint(Self.dialogScreen, modes: ""))
        await fixture.scripted.releaseAttachReplies()
        await pressing.value

        #expect(card.notice == BlockedCardStore.changedMessage)
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    @Test func anUnreadableCardsKeyPressesNothingOnceTheAgentLeavesWhileItsViewerOpens() async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.unreadableCard()
        let (pressing, viewer) = try await fixture.keyWaitingForItsViewer(on: card)

        try await fixture.deliverEvent("foreground", data: Self.foreground(pid: 41, argv: ["bash"]))
        try await Self.until("the Agent to go") { fixture.console.agents.isEmpty }
        await fixture.scripted.releaseAttachReplies()
        await pressing.value

        #expect(card.notice?.contains("no longer holds this terminal") == true, "\(card.notice ?? "")")
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty)
        fixture.finish()
    }

    private static func expectKeyPadPressesNothing(
        onceThePaintIs next: Data, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let fixture = try await Fixture(terminal: Self.record(status: "blocked"), modes: "")
        let card = try await fixture.keyPadCard(showing: try Self.previewsPaint())
        let shown = card.content
        let (pressing, viewer) = try await fixture.keyWaitingForItsViewer(on: card)

        await fixture.scripted.setAttachPaint(next)
        await fixture.scripted.releaseAttachReplies()
        await pressing.value

        #expect(card.notice == BlockedCardStore.changedMessage, sourceLocation: sourceLocation)
        #expect(card.progress == .ready, sourceLocation: sourceLocation)
        #expect(card.content != shown, "The card shows what the key would have gone over", sourceLocation: sourceLocation)
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        #expect(await fixture.written(on: viewer).isEmpty, sourceLocation: sourceLocation)
        fixture.finish()
    }

    // MARK: Keys and text

    @Test func aPasteGoesThroughAViewerInTheFormTheProgramTakes() async throws {
        let bracketed = try await Fixture()
        try await bracketed.console.pasteIntoAgent("hello", paneID: "t1", on: bracketed.host.id)
        #expect(await bracketed.written(on: try await bracketed.viewer()) == [Self.paste])
        bracketed.finish()

        let plain = try await Fixture(modes: "")
        try await plain.console.pasteIntoAgent("hello", paneID: "t1", on: plain.host.id)
        #expect(await plain.written(on: try await plain.viewer()) == ["hello"])
        plain.finish()
    }

    /// Every name `agent.send_keys` gets from Chat's keys and its dialogs.
    @Test(arguments: [
        ("esc", "\u{1B}"), ("enter", "\r"), ("tab", "\t"), ("shift+tab", "\u{1B}[Z"), ("left", "\u{1B}[D"),
        ("up", "\u{1B}[A"), ("down", "\u{1B}[B"), ("right", "\u{1B}[C"), ("backspace", "\u{7F}"), ("space", " "),
        ("ctrl+c", "\u{3}"), ("ctrl+]", "\u{1D}"), ("ctrl+q", "\u{11}"), ("shift+left", "\u{1B}[1;2D"),
        ("f1", "\u{1B}OP"), ("1", "1"), ("a", "a"), ("A", "A"), ("plus", "+"), ("/", "/"), ("é", "é"),
    ])
    func aKeyNameReadsAsTheBytesItsKeySends(name: String, bytes: String) {
        #expect(HerdrCoreChatTyping.bytes(forKeyNamed: name, modes: TerminalModeTracker()) == Data(bytes.utf8))
    }

    @Test func aNameThatIsNoKeyHasNoBytes() {
        #expect(HerdrCoreChatTyping.bytes(forKeyNamed: "hyper+nothing", modes: TerminalModeTracker()) == nil)
    }
}

/// A dialog that takes a note: what a card's steps type, and what each one's check
/// says of the screen it would go over.
private actor NoteDialogPane {
    private(set) var screen: ANSIScreen
    private(set) var typed: [String] = []
    private(set) var answersOnItsDialog: [Bool] = []
    private(set) var answersOnAnotherDialog: [Bool] = []
    private let afterPaste: ANSIScreen
    private let afterEnter: ANSIScreen
    private let anotherDialog: ANSIScreen

    init(showing: ANSIScreen, afterPaste: ANSIScreen, afterEnter: ANSIScreen, anotherDialog: ANSIScreen) {
        screen = showing
        self.afterPaste = afterPaste
        self.afterEnter = afterEnter
        self.anotherDialog = anotherDialog
    }

    func type(_ typing: BlockedScreenIO.Typing, whileShowing check: @Sendable (ANSIScreen) -> Bool) {
        answersOnItsDialog.append(check(screen))
        answersOnAnotherDialog.append(check(anotherDialog))
        switch typing {
        case .paste(let text):
            typed.append("paste \(text)")
            screen = afterPaste
        case .keys(let keys):
            typed.append("keys \(keys.joined(separator: " "))")
            screen = afterEnter
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
