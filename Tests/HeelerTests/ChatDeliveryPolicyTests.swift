import Foundation
import Testing

@testable import Heeler

/// Chat's delivery policy: the screen checks around a send, read through
/// `agent.read` and never through the PTY.
@MainActor
@Suite("Chat delivery policy")
struct ChatDeliveryPolicyTests {
    private static let rules = ChatSendRules(
        program: .codex, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .codex))
    private static let grokRules = ChatSendRules(
        program: .grok, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .grok))

    /// Codex's composer holding a draft the user typed in the terminal.
    private static func draft(_ text: String) -> ANSIScreen {
        ScreenFixture.synthetic(
            ["• Done.", "", SGR.bold + "›" + SGR.reset + " " + text, "",
             "  " + SGR.bold + "? " + SGR.reset + "for shortcuts"])
    }

    @MainActor
    private final class Reads {
        var count = 0
        var pauses: [Duration] = []
    }

    private static func policy(
        activity: ChatAgentActivity = .idle, reads: Reads = Reads(),
        screen: @escaping @MainActor () throws -> ANSIScreen
    ) -> ComposerDeliveryPolicy {
        .chat(
            rules: rules, activity: { activity },
            readScreen: {
                reads.count += 1
                return try screen()
            },
            pause: { duration in await MainActor.run { reads.pauses.append(duration) } })
    }

    @Test func anEmptyInputBoxLetsTheMessageGo() async throws {
        let ready = try ScreenFixture.screen("codex-00-ready")
        let preflight = try #require(Self.policy { ready }.preflight)

        #expect(await preflight("hello") == nil)
    }

    @Test func aBlockedAgentIsRefusedWithoutReadingTheScreen() async throws {
        let reads = Reads()
        let preflight = try #require(Self.policy(activity: .blocked, reads: reads) { Self.draft("") }.preflight)

        #expect(await preflight("hello") == .agentBlocked)
        #expect(reads.count == 0)
    }

    /// Each program's idle capture with an empty input box.
    private static let readyScreens: [ChatProgram: String] = [
        .claude: "claude-01-ready", .codex: "codex-00-ready", .pi: "pi-06-empty-editor-119",
        .omp: "omp-08-empty-120-after-first", .grok: "grok-01-idle-empty",
        .opencode: "opencode-02-session-empty-180",
    ]

    /// Without a session check, a send reads the screen once and goes into
    /// an empty box, and a Blocked Agent refuses it unread.
    @Test(arguments: ChatProgram.allCases)
    func withoutASessionCheckNothingChanges(program: ChatProgram) async throws {
        let ready = try ScreenFixture.screen(try #require(Self.readyScreens[program]))
        let rules = ChatSendRules(
            program: program, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: program))
        let reads = Reads()
        func preflight(_ activity: ChatAgentActivity) throws -> @MainActor (String) async -> ComposerRefusal? {
            try #require(
                ComposerDeliveryPolicy.chat(
                    rules: rules, activity: { activity },
                    readScreen: {
                        reads.count += 1
                        return ready
                    }
                ).preflight)
        }

        let idle = try preflight(.idle)
        let blocked = try preflight(.blocked)

        #expect(await idle("hello") == nil)
        #expect(reads.count == 1)
        #expect(await blocked("hello") == .agentBlocked)
        #expect(reads.count == 1)
    }

    @MainActor
    private final class Calls {
        var names: [String] = []
    }

    /// The session check runs after the Blocked check and before the screen
    /// read: a reason refuses the message unread, and nil lets the read go
    /// on.
    @Test func aSessionCheckRunsBeforeTheScreenAndCanRefuse() async throws {
        let ready = try ScreenFixture.screen("opencode-02-session-empty-180")
        let reason = "OpenCode's terminal shows another conversation (Other). Open this one in the terminal, then send again."
        let calls = Calls()
        func preflight(
            _ activity: ChatAgentActivity, check: String?
        ) throws -> @MainActor (String) async -> ComposerRefusal? {
            try #require(
                ComposerDeliveryPolicy.chat(
                    rules: Self.openCodeRules, activity: { activity },
                    readScreen: {
                        calls.names.append("read")
                        return ready
                    },
                    confirmSession: {
                        calls.names.append("check")
                        return check
                    }
                ).preflight)
        }

        let blocked = try preflight(.blocked, check: reason)
        let refused = try preflight(.idle, check: reason)
        let confirmed = try preflight(.idle, check: nil)

        #expect(await blocked("hello") == .agentBlocked)
        #expect(calls.names.isEmpty)
        #expect(await refused("hello") == .inputNotReady(reason))
        #expect(calls.names == ["check"])
        #expect(await confirmed("hello") == nil)
        #expect(calls.names == ["check", "check", "read"])
    }

    @Test func textAlreadyInTheBoxHoldsTheMessage() async throws {
        let preflight = try #require(Self.policy { Self.draft("half typed") }.preflight)

        #expect(await preflight("hello") == .inputNotReady(InputBoxState.text("half typed").holdReason(for: .codex)))
    }

    /// Esc in Pi and Oh My Pi puts a steer the turn had not taken back into
    /// the input box, which then holds Chat's next message; so does a draft
    /// typed there, with nothing queued.
    @Test func aPiDraftMentionsWhatStopPutBack() {
        for program in [ChatProgram.pi, .omp] {
            #expect(
                InputBoxState.text("steer").holdReason(for: program)
                    == "The Agent's input box already has text, such as a draft or a steer that Stop returned. Send or clear it in the terminal first."
            )
        }
        #expect(!InputBoxState.text("draft").holdReason(for: .claude).contains("Stop"))
    }

    /// herdr reports Codex idle under its plan selector, so no card names
    /// it; the hold does. Every other dialog keeps the general copy.
    @Test func aCodexPlanSelectorIsNamedInTheHold() {
        let plan = InputBoxState.dialog(title: "Implement this plan?")
        #expect(
            plan.holdReason(for: .codex)
                == "Codex is asking whether to implement the plan. Answer it in the terminal first.")
        let general = "The Agent is showing a dialog. Answer it in the terminal first."
        #expect(InputBoxState.dialog(title: nil).holdReason(for: .codex) == general)
        #expect(plan.holdReason(for: .claude) == general)
    }

    /// Codex 0.162.1's Esc puts a follow-up queued with Tab back into the
    /// composer, which then holds Chat's next message.
    @Test func aCodexDraftMentionsWhatStopPutBack() {
        #expect(
            InputBoxState.text("follow-up").holdReason(for: .codex)
                == "The Agent's input box already has text, such as a draft or a message Stop returned. Send or clear it in the terminal first."
        )
        #expect(
            InputBoxState.text("draft").holdReason(for: .claude)
                == "The Agent's input box already has text. Send or clear it in the terminal first.")
    }

    /// OpenCode's `/undo` puts the undone prompt back in the box, and Up
    /// recalls an earlier one; the hold names both beside a draft.
    @Test func openCodeDraftHoldNamesUndoAndHistory() {
        #expect(
            InputBoxState.text("draft").holdReason(for: .opencode)
                == "The Agent's input box already has text, such as a draft, a prompt /undo put back, or one recalled with Up. Send or clear it in the terminal first."
        )
    }

    /// A home screen, dashboard or picker in place of the conversation's
    /// input box holds with the sentence the program's detector gave.
    @Test(arguments: ChatProgram.allCases)
    func aScreenWithNoComposerHoldsWithItsOwnReason(program: ChatProgram) {
        let reason = "Open this conversation in the terminal first."

        #expect(InputBoxState.noComposer(reason).holdReason(for: program) == reason)
    }

    private static let openCodeRules = ChatSendRules(
        program: .opencode, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .opencode))

    /// A message on OpenCode's home screen would start a new conversation,
    /// not continue the one Chat shows.
    @Test func openCodeHomeHoldsWithItsOwnReason() async throws {
        let home = try ScreenFixture.screen("opencode-01-home-empty-180")
        let preflight = try #require(
            ComposerDeliveryPolicy.chat(rules: Self.openCodeRules, activity: { .idle }, readScreen: { home }).preflight)

        #expect(
            await preflight("hello")
                == .inputNotReady(
                    "OpenCode is on its home screen, where a message starts a new conversation. Open this conversation in the terminal first."
                ))
    }

    /// While OpenCode works, herdr's Enter could answer a prompt that shows
    /// first, so the message waits for the turn to end.
    @Test func openCodeWorkingHoldsWithItsOwnReason() async throws {
        let working = try ScreenFixture.screen("opencode-08-working-180")
        let preflight = try #require(
            ComposerDeliveryPolicy.chat(rules: Self.openCodeRules, activity: { .working }, readScreen: { working })
                .preflight)

        #expect(
            await preflight("hello")
                == .inputNotReady(
                    "The Agent isn't taking messages: OpenCode is working. Send once it's idle, or steer from the terminal."
                ))
    }

    @Test func anUnreadableScreenHoldsTheMessage() async throws {
        let preflight = try #require(Self.policy { throw TransportError.timedOut }.preflight)

        let refusal = await preflight("hello")

        guard case .inputNotReady(let reason) = refusal else {
            Issue.record("Expected inputNotReady, got \(String(describing: refusal))")
            return
        }
        #expect(reason.hasPrefix("Heeler couldn't check the Agent's input box."))
        #expect(refusal?.suggestsTerminal == true)
    }

    @Test func textLeftInTheBoxAfterTheDelayIsNotDelivered() async throws {
        let reads = Reads()
        let verify = try #require(Self.policy(reads: reads) { Self.draft("hello") }.verify)

        #expect(await verify("hello ") == false)
        #expect(reads.pauses == [DeliveryCheck.delay])
    }

    @Test func anEmptiedBoxOrAnUnreadableScreenCountsAsSent() async throws {
        let ready = try ScreenFixture.screen("codex-00-ready")
        let emptied = try #require(Self.policy { ready }.verify)
        let unreadable = try #require(Self.policy { throw TransportError.timedOut }.verify)

        #expect(await emptied("hello ") == true)
        #expect(await unreadable("hello ") == true)
    }

    /// What the Agent's state held ends with that state, for every program;
    /// what the rules refuse in the text waits for the text to change.
    @Test(arguments: ChatProgram.allCases)
    func holdsOnTheAgentEndWithTheirStateAndRefusalsOfTheTextDoNot(program: ChatProgram) async throws {
        let busy = ChatSendRules(
            program: program, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: false, program: program))
        let blocked = try #require(
            ComposerDeliveryPolicy.chat(rules: busy, activity: { .blocked }, readScreen: { Self.draft("") }).preflight)
        let unreadable = try #require(
            ComposerDeliveryPolicy.chat(
                rules: busy, activity: { .working }, readScreen: { throw TransportError.timedOut }
            ).preflight)
        let statuses: [AgentStatus] = [.idle, .working, .blocked, .done, .unknown]
        func ending(_ refusal: ComposerRefusal?) throws -> [AgentStatus] {
            let refusal = try #require(refusal)
            return statuses.filter { refusal.endsWhenStatusBecomes($0) }
        }

        #expect(try ending(await blocked("hello")) == [.idle, .working, .done, .unknown])
        #expect(try ending(busy.validate("/compact")) == [.idle, .done])
        #expect(try ending(await unreadable("hello")) == statuses)
        for state in [
            InputBoxState.text("draft"), .disabled("Working."), .overlay("/compact"), .dialog(title: nil),
            .noComposer(""), .unknown(""),
        ] {
            #expect(try ending(.inputNotReady(state.holdReason(for: program))) == statuses)
        }
        for refusal in [busy.validate("!ls"), busy.validate("/nope")] {
            #expect(try ending(refusal).isEmpty)
        }
    }

    @Test func ompRefusalsOfTheTextOutliveEveryStatus() throws {
        let rules = ChatSendRules(
            program: .omp, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .omp))

        for draft in ["exit", "$ print(1)", ".", "-> later", "/compact keep the notes"] {
            let refusal = try #require(rules.validate(draft))
            for status in [AgentStatus.idle, .working, .blocked, .done, .unknown] {
                #expect(!refusal.endsWhenStatusBecomes(status), "\(draft)")
            }
        }
    }

    /// Grok Build's holds name what to resolve in the terminal.
    @Test(arguments: [
        "grok-02-idle-draft", "grok-07-slash-popup", "grok-11-dashboard", "grok-21-resume-picker",
        "grok-26-waiting-subagent",
    ])
    func grokNamesWhatHoldsTheSend(stem: String) async throws {
        let reasons = [
            "grok-02-idle-draft":
                "Grok Build's input box already has text, such as a draft or a message Stop put back. Send or clear it in the terminal first.",
            "grok-07-slash-popup": "A menu is open over the Agent's input box. Close it in the terminal first.",
            "grok-11-dashboard":
                "Grok Build is showing its dashboard, where a message starts a new agent. Go back to the conversation in the terminal first.",
            "grok-21-resume-picker": "A menu is open over the Agent's input box. Close it in the terminal first.",
            "grok-26-waiting-subagent":
                "The Agent isn't taking messages: Grok Build is waiting on a subagent or a background task, and a message now would cancel that turn.",
        ]
        let reason = try #require(reasons[stem])
        let screen = try ScreenFixture.screen(stem)
        let policy = ComposerDeliveryPolicy.chat(rules: Self.grokRules, activity: { .working }, readScreen: { screen })
        let preflight = try #require(policy.preflight)

        #expect(await preflight("hello") == .inputNotReady(reason))
    }

    /// The re-read compares what the box holds with the text sent: Grok
    /// Build puts a stashed draft back after a send.
    @Test func grokVerifyComparesTheBoxWithTheSentText() async throws {
        let restored = try ScreenFixture.screen("grok-24-restored-draft")
        let verify = try #require(
            ComposerDeliveryPolicy.chat(
                rules: Self.grokRules, activity: { .idle }, readScreen: { restored }, pause: { _ in }
            ).verify)

        #expect(await verify("Reply with the word kiwi. ") == false)
        #expect(await verify("Summarize the README ") == true)
    }

    /// The order a send's steps ran in, or what one was handed.
    @MainActor
    private final class Events {
        var entries: [String] = []
    }

    /// What Chat knows beyond the input box, such as Grok Build showing
    /// another session, holds a send the box would take. It gets the text
    /// as herdr types it and the screen the box was read from.
    @Test func aSendConcernHoldsAfterTheInputBoxPasses() async throws {
        let ready = try ScreenFixture.screen("grok-01-idle-empty")
        let draft = try ScreenFixture.screen("grok-02-idle-draft")
        let asked = Events()
        let concern: @MainActor (String, ANSIScreen) -> String? = { text, screen in
            asked.entries.append(text)
            return screen.rows == ready.rows ? "Held for what Chat knows." : nil
        }
        let preflight = try #require(
            ComposerDeliveryPolicy.chat(
                rules: Self.grokRules, activity: { .idle }, readScreen: { ready }, sendConcern: concern
            ).preflight)
        let gated = try #require(
            ComposerDeliveryPolicy.chat(
                rules: Self.grokRules, activity: { .idle }, readScreen: { draft }, sendConcern: concern
            ).preflight)

        #expect(await preflight("hello") == .inputNotReady("Held for what Chat knows."))
        #expect(asked.entries == ["hello "])
        // A box the gate holds never gets that far.
        #expect(
            await gated("hello")
                == .inputNotReady(
                    "Grok Build's input box already has text, such as a draft or a message Stop put back. Send or clear it in the terminal first."
                ))
        #expect(asked.entries == ["hello "])
    }

    /// Nothing is awaited between the screen read, the check and the
    /// paste, so the check sees the screen the paste meets.
    @Test func theSendConcernRunsBetweenTheGateAndThePrompt() async throws {
        let ready = try ScreenFixture.screen("grok-01-idle-empty")
        let draft = try ScreenFixture.screen("grok-02-idle-draft")
        let events = Events()
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            await MainActor.run { events.entries.append("prompt") }
            return try await transport.promptAgent(params)
        }
        func policy(_ screen: ANSIScreen) -> ComposerDeliveryPolicy {
            .chat(
                rules: Self.grokRules, activity: { .idle },
                readScreen: {
                    events.entries.append("read")
                    return screen
                },
                sendConcern: { _, _ in
                    events.entries.append("concern")
                    return nil
                },
                pause: { _ in })
        }

        composer.replaceDraft(with: "hello")
        await composer.send(policy: policy(ready))
        #expect(Array(events.entries.prefix(3)) == ["read", "concern", "prompt"])

        // Held at the input box: neither the check nor the paste runs.
        events.entries = []
        composer.replaceDraft(with: "again")
        await composer.send(policy: policy(draft))
        #expect(events.entries.filter { $0 != "read" }.isEmpty)
        #expect(await transport.agentPromptParams.count == 1)
    }

    /// Chat registers the send just before the screen read, so the
    /// witness mark a new send takes is on its way before `agent.read`. A
    /// Blocked Agent's send, refused first, registers nothing.
    @Test func theSendRegistersBeforeTheScreenRead() async throws {
        let ready = try ScreenFixture.screen("grok-01-idle-empty")
        let events = Events()
        let readScreen: @MainActor () async throws -> ANSIScreen = {
            events.entries.append("read")
            return ready
        }
        let concern: @MainActor (String, ANSIScreen) -> String? = { _, _ in
            events.entries.append("concern")
            return nil
        }
        let register: @MainActor () -> Void = { events.entries.append("register") }
        let preflight = try #require(
            ComposerDeliveryPolicy.chat(
                rules: Self.grokRules, activity: { .idle }, readScreen: readScreen, sendConcern: concern,
                willReadScreen: register
            ).preflight)
        let blocked = try #require(
            ComposerDeliveryPolicy.chat(
                rules: Self.grokRules, activity: { .blocked }, readScreen: readScreen, sendConcern: concern,
                willReadScreen: register
            ).preflight)

        #expect(await preflight("hello") == nil)
        #expect(events.entries == ["register", "read", "concern"])
        events.entries = []
        #expect(await blocked("hello") == .agentBlocked)
        #expect(events.entries.isEmpty)
    }

    @Test func theRulesShapeWhatIsSentAndRefused() {
        let policy = Self.policy { Self.draft("") }

        #expect(policy.route == .chat)
        #expect(!policy.insertsIntoAttachWhenBlocked)
        #expect(policy.outgoingText("/compact") == "/compact ")
        #expect(policy.validate("!rm -rf build") != nil)
    }
}

/// Chat's reading of the Composer's messages: what the store matches, and
/// the echoes it still shows.
@MainActor
@Suite("Chat Composer echoes")
struct ChatComposerEchoesTests {
    private static let rules = ChatSendRules(
        program: .codex,
        commands: ChatCommandMenu.commands(
            skills: [AgentSkill(scope: .global, name: "review", description: nil, commandPrefix: "$")],
            agentIsIdle: true, program: .codex))

    private static func policy(verify: (@MainActor (String) async -> Bool)? = nil) -> ComposerDeliveryPolicy {
        ComposerDeliveryPolicy(
            route: .chat, insertsIntoAttachWhenBlocked: false, outgoingText: { rules.outgoingText($0) },
            validate: { rules.validate($0) }, preflight: nil, verify: verify)
    }

    private static func store(_ transport: ScriptedTransport) -> AgentComposerStore {
        AgentComposerStore(target: "w1:p1") { params in try await transport.promptAgent(params) }
    }

    @Test func onlyChatsMessagesAreMatchedAsHerdrTypedThem() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "from the terminal")
        await store.send()
        store.replaceDraft(with: "/review the diff")
        await store.send(policy: Self.policy())

        let sent = ChatComposerEchoes.sentMessages(store.messages, rules: Self.rules)

        #expect(sent.map(\.text) == ["$review the diff "])
        #expect(sent.map(\.isDelivered) == [true])
    }

    @Test func aRecordedMessageGivesWayToItsEntry() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "one")
        await store.send(policy: Self.policy())
        store.replaceDraft(with: "two")
        await store.send(policy: Self.policy())
        let ids = store.messages.map(\.id)

        let echoes = ChatComposerEchoes.pending(
            store.messages, statuses: [ids[0]: .recorded, ids[1]: .overdue])

        #expect(echoes.map(\.text) == ["two"])
        #expect(echoes.map(\.state) == [.unconfirmed])
    }

    @Test func aMessageTheStoreHasNotSeenGetsNoEcho() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "earlier")
        await store.send(policy: Self.policy())

        #expect(ChatComposerEchoes.pending(store.messages, statuses: [:]).isEmpty)
    }

    @Test func onlyTheLatestFailureShows() async {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailures([TransportError.timedOut, TransportError.timedOut])
        let store = Self.store(transport)
        store.replaceDraft(with: "first")
        await store.send(policy: Self.policy())
        store.replaceDraft(with: "second")
        await store.send(policy: Self.policy())

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [:])

        #expect(echoes.map(\.text) == ["second"])
        guard case .failed = echoes.first?.state else {
            Issue.record("Expected a failed echo")
            return
        }
    }

    @Test func textLeftInTheInputBoxShowsAsNotDelivered() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "stuck")
        await store.send(policy: Self.policy(verify: { _ in false }))
        try await waitUntil("the verify task should mark the message") {
            store.messages.first?.state == .undelivered
        }
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [id: .awaiting])

        #expect(echoes.map(\.state) == [.notDelivered])
    }

    /// Text left in the input box that the user cleared there since: what
    /// the Chat store last saw in the box outranks the check after the send.
    @Test func textClearedFromTheInputBoxSinceShowsAsDiscarded() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "stuck")
        await store.send(policy: Self.policy(verify: { _ in false }))
        try await waitUntil("the verify task should mark the message") {
            store.messages.first?.state == .undelivered
        }
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [id: .discarded])

        #expect(echoes.map(\.state) == [.discarded])
    }

    /// A `/compact` Pi said it had nothing to compact for.
    @Test func aRefusedSendSaysWhatTheProgramSaid() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "/compact")
        await store.send(policy: Self.policy())
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(
            store.messages, statuses: [id: .refused("Pi had nothing to compact.")])

        #expect(echoes.map(\.state) == [.refused("Pi had nothing to compact.")])
    }

    /// The Agent's own log says another session took the send, which
    /// outranks the check after the send finding its text in the box.
    @Test func aMisdirectedSendSaysWhereItWent() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "say KIWI")
        await store.send(policy: Self.policy())
        store.replaceDraft(with: "stuck")
        await store.send(policy: Self.policy(verify: { _ in false }))
        try await waitUntil("the verify task should mark the message") {
            store.messages.last?.state == .undelivered
        }
        let ids = store.messages.map(\.id)

        let echoes = ChatComposerEchoes.pending(
            store.messages, statuses: [ids[0]: .misdirected, ids[1]: .misdirected])

        #expect(echoes.map(\.state) == [.misdirected, .misdirected])
    }

    /// A steer Esc put back in Pi's or Oh My Pi's input box.
    @Test func aSendFoundBackInTheInputBoxShowsAsNotDelivered() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "say KIWI")
        await store.send(policy: Self.policy())
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [id: .returned])

        #expect(echoes.map(\.state) == [.notDelivered])
    }

    /// A steer Esc put back that the user then cleared in the terminal: it
    /// was never delivered, so it never reads as sent.
    @Test func aSendClearedFromTheInputBoxShowsAsDiscarded() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "say KIWI")
        await store.send(policy: Self.policy())
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [id: .discarded])

        #expect(echoes.map(\.state) == [.discarded])
    }

    /// Like a failure, a discarded send shows only while it is Chat's
    /// latest message; one sent since moves the conversation on.
    @Test func aDiscardedSendGivesWayToANewerMessage() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "say KIWI")
        await store.send(policy: Self.policy())
        store.replaceDraft(with: "say yes")
        await store.send(policy: Self.policy())
        let ids = store.messages.map(\.id)

        let echoes = ChatComposerEchoes.pending(
            store.messages, statuses: [ids[0]: .discarded, ids[1]: .awaiting])

        #expect(echoes.map(\.text) == ["say yes"])
        #expect(echoes.map(\.state) == [.sent])
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}
