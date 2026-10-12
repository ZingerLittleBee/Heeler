import Foundation
import Testing

@testable import Heeler

/// The Blocked card against captured screens: what it shows, the keys it
/// sends and when, and how it knows they worked.
@MainActor
@Suite("Blocked card store", .timeLimit(.minutes(1)))
struct BlockedCardStoreTests {
    @Test func aBlockedAgentsDialogShowsAsACardWithItsRequest() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(transcript: Self.transcript(pending: [Self.bash("toolu_old", "rm -rf build"), Self.bash("toolu_1", "touch c1.txt")]))
        store.update(activity: .blocked)

        await store.refresh()

        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .claudeBash)
        #expect(card.request?.callID == "toolu_1")
        #expect(store.progress == .ready)
    }

    @Test func anOptionWaitsOutTheGraceThenSendsItsDigitOnce() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
        let clock = ManualClock()
        let store = Self.store(.claude, pane: pane, clock: clock)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(clock.sleeps.first == .milliseconds(150))
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        store.update(activity: .working)
        #expect(store.content == .none)
    }

    @Test func aDialogThatChangedBeforeTheTapGetsNoKeys() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-30-par-first"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        await pane.show(try ScreenFixture.screen("claude-31-par-second"))

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys.isEmpty)
        #expect(store.notice == "This prompt changed. Check it before answering.")
        guard case .card(let card) = store.content else {
            Issue.record("Expected the new dialog's card, got \(store.content)")
            return
        }
        #expect(card.dialog.subject.command == "touch par-b.txt")
    }

    @Test func aStepTheDialogIgnoresStopsTheKeysAndFallsBackToTheGenericCard() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.amend(ordinal: 4, note: "Skip it"))

        // The first arrow never moved focus, so nothing follows it.
        #expect(await pane.keys == [["down"]])
        #expect(await pane.pastes.isEmpty)
        guard case .generic(let excerpt) = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
        #expect(excerpt.numbered.count == 4)
        #expect(excerpt.numbered[4] == "No")
        #expect(store.notice?.hasPrefix("The dialog didn't respond") == true)

        // The generic card's buttons still answer it, by digit.
        await pane.react(to: ["4"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
        await store.press(number: 4)
        #expect(await pane.keys == [["down"], ["4"]])
        #expect(store.progress == .ready)
    }

    @Test func noEffectLeavesTheCardWaitingForAFreshReadAndNeverResends() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.progress == .unconfirmed)
        #expect(store.notice == "The Agent hasn't responded yet.")
        await store.perform(.choose(ordinal: 1))
        #expect(await pane.keys == [["1"]])

        await store.refresh()
        #expect(store.progress == .ready)
    }

    @Test func aClaudeCardConfirmsByItsCallsResult() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let request = Self.bash("toolu_1", "touch c1.txt")
        let box = StoreBox()
        let store = BlockedCardStore(
            program: .claude,
            io: BlockedScreenIO(
                readScreen: { await pane.read() },
                sendKeys: { keys in
                    await pane.send(keys)
                    // The program records the result; the dialog still shows.
                    await MainActor.run {
                        box.store?.update(transcript: Self.transcript(resolved: [request]))
                    }
                },
                paste: { await pane.paste($0) }),
            clock: ManualClock().clock)
        box.store = store
        store.update(transcript: Self.transcript(pending: [request]))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    @Test func aCodexDeclineHandsTheTurnToTheComposer() async throws {
        let pane = FakePane(try ScreenFixture.screen("codex-01-x1-exec"))
        await pane.react(to: ["3"], with: try ScreenFixture.screen("codex-00-ready"))
        let store = Self.store(.codex, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 3))

        #expect(await pane.keys == [["3"]])
        #expect(store.composerFocusRequest == 1)
        #expect(store.progress == .ready)
    }

    @Test func answersTheTranscriptCantShowAreKeptOnceTheyTakeEffect() async throws {
        let request = Self.bash("toolu_1", "touch c1.txt")
        for (action, keys, expected) in [
            (DialogAction.choose(ordinal: 1), ["1"], ChatToolActivity.CardAnswer?.some(.allowed)),
            (.dismiss, ["esc"], .stopped),
            // The transcript records a decline itself.
            (.choose(ordinal: 4), ["4"], nil),
        ] {
            let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
            await pane.react(to: keys, with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
            let store = Self.store(.claude, pane: pane)
            store.update(transcript: Self.transcript(pending: [request]))
            store.update(activity: .blocked)
            await store.refresh()

            await store.perform(action)

            #expect(await pane.keys == [keys])
            #expect(store.history.calls["toolu_1"] == expected, "\(action)")
        }
    }

    @Test func anAnswerThatShowedNoEffectIsNotKept() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(transcript: Self.transcript(pending: [Self.bash("toolu_1", "touch c1.txt")]))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(store.progress == .unconfirmed)
        #expect(store.history.isEmpty)
    }

    @Test func aCodexAsynchronousAnswerIsQueuedUnderItsQuestion() async throws {
        let pane = FakePane(try ScreenFixture.screen("codex-09-x4-expanded"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("codex-10-x4-after-digit"))
        let store = Self.store(.codex, pane: pane)
        let request = ChatPendingRequest(
            entryID: ChatEntryID("item-1"), callID: "item-1", kind: .question, toolName: "request_user_input_async",
            summary: "Pick a fruit",
            questions: [ChatQuestion(id: "item-1:0", text: "Pick a fruit"), ChatQuestion(id: "item-1:1", text: "Pick a drink")])
        store.update(transcript: ChatTranscript(entries: [], pendingRequests: [request]))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.history.queuedAnswers == ["item-1:0": "Apple"])
        #expect(store.history.calls.isEmpty)
    }

    @Test func oneActionAtATime() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        async let first: Void = store.perform(.choose(ordinal: 1))
        async let second: Void = store.perform(.choose(ordinal: 1))
        _ = await (first, second)

        #expect(await pane.keys == [["1"]])
    }

    @Test func aScreenWithNoDialogWhileBlockedSaysSoOnlyAfterAMoment() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-01-ready"))
        let clock = ManualClock()
        let store = Self.store(.claude, pane: pane, clock: clock)
        store.update(activity: .blocked)

        // herdr reports Blocked a moment before the dialog draws.
        await store.refresh()
        #expect(store.content == .none)
        clock.advance(.seconds(2))
        await store.refresh()
        #expect(store.content == .unreadable)

        store.update(activity: .idle)
        #expect(store.content == .none)
        await store.refresh()
        #expect(store.content == .none)
    }

    @Test func anAnsweredDialogLeavesNothingBehindWhileBlockedLingers() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
        let clock = ManualClock()
        let store = Self.store(.claude, pane: pane, clock: clock)
        store.update(activity: .blocked)
        clock.advance(.seconds(5))
        await store.refresh()

        await store.perform(.choose(ordinal: 1))
        await store.refresh()

        #expect(store.content == .none)
    }

    @Test func aNewDialogUnfoldsACollapsedCard() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-30-par-first"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        store.isCollapsed = true

        await store.refresh()
        #expect(store.isCollapsed)
        await pane.show(try ScreenFixture.screen("claude-31-par-second"))
        await store.refresh()
        #expect(!store.isCollapsed)
    }

    @Test func keyPadKeysGoAsTheyAre() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        await pane.react(to: ["down"], with: try ScreenFixture.screen("claude-03-c1-focus-no"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.sendKeys(["down"])

        #expect(await pane.keys == [["down"]])
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.focus.focusedOrdinal == 4)
    }

    // MARK: Helpers

    private static func store(_ program: ChatProgram, pane: FakePane, clock: ManualClock = ManualClock()) -> BlockedCardStore {
        BlockedCardStore(
            program: program,
            io: BlockedScreenIO(
                readScreen: { await pane.read() },
                sendKeys: { await pane.send($0) },
                paste: { await pane.paste($0) }),
            clock: clock.clock)
    }

    private static func bash(_ id: String, _ command: String) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: .command, toolName: "Bash", summary: command)
    }

    private static func transcript(
        pending: [ChatPendingRequest] = [], resolved: [ChatPendingRequest] = []
    ) -> ChatTranscript {
        let entries = (pending.map { ($0, ChatToolActivity.Status.awaitingApproval) }
            + resolved.map { ($0, ChatToolActivity.Status.succeeded) }).enumerated().map { index, item in
                ChatEntry(
                    id: item.0.entryID, sourceOffset: UInt64(index),
                    content: .tool(
                        ChatToolActivity(
                            kind: item.0.kind, name: item.0.toolName, title: item.0.summary, status: item.1,
                            callID: item.0.callID)))
            }
        return ChatTranscript(entries: entries, pendingRequests: pending)
    }
}

@MainActor
private final class StoreBox {
    weak var store: BlockedCardStore?
}

/// The Agent's pane: one screen at a time, which keys can replace.
private actor FakePane {
    private var screen: ANSIScreen
    private var reactions: [[String]: ANSIScreen] = [:]
    private(set) var keys: [[String]] = []
    private(set) var pastes: [String] = []

    init(_ screen: ANSIScreen) {
        self.screen = screen
    }

    func read() -> ANSIScreen { screen }

    func show(_ screen: ANSIScreen) {
        self.screen = screen
    }

    func react(to keys: [String], with screen: ANSIScreen) {
        reactions[keys] = screen
    }

    func send(_ keys: [String]) {
        self.keys.append(keys)
        if let next = reactions[keys] { screen = next }
    }

    func paste(_ text: String) {
        pastes.append(text)
    }
}

@Suite("Agent quick key names")
struct AgentQuickKeyHerdrNameTests {
    @Test func everyKeyThePadSendsIsOneHerdrAccepts() {
        let pad: [AgentQuickKey] = [.escape, .tab, .backspace, .left, .up, .right, .shiftTab, .down, .enter]
        for key in pad {
            let name = key.herdrKeyName
            #expect(name.map(HerdrKeyGrammar.accepts) == true, "\(key) as \(String(describing: name))")
        }
        #expect(AgentQuickKey.character("+").herdrKeyName == "plus")
        #expect(AgentQuickKey.character(" ").herdrKeyName == "space")
        #expect(AgentQuickKey.function(.f5).herdrKeyName == "f5")
    }

    @Test func keysHerdrHasNoNameForStayUnsent() {
        for key: AgentQuickKey in [.home, .end, .insert, .forwardDelete, .pageUp, .pageDown, .character("👍🏽")] {
            #expect(key.herdrKeyName == nil)
        }
    }
}

@Suite("Blocked request match")
struct BlockedRequestMatchTests {
    private func dialog(_ stem: String) throws -> BlockedDialog {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    private func request(
        _ id: String, _ tool: String, _ summary: String, kind: ChatToolActivity.Kind = .command,
        questions: [ChatQuestion] = []
    ) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: kind, toolName: tool, summary: summary, questions: questions)
    }

    @Test func aBashDialogMatchesItsCommandEvenWrappedNarrow() throws {
        let requests = [
            request("a", "Bash", "touch other.txt"), request("b", "Bash", "touch n1.txt"),
            request("c", "Bash", "touch n1.txt"),
        ]
        // Two identical calls: the older one asked first.
        #expect(BlockedRequestMatch.request(for: try dialog("claude-27-n1-narrow-bash"), in: requests)?.callID == "b")
    }

    @Test func aCutOffCommandMatchesTheCallItStarts() throws {
        let requests = [request("a", "Bash", "touch c1.txt && echo done")]
        #expect(BlockedRequestMatch.request(for: try dialog("claude-02-c1-bash-blocked"), in: requests)?.callID == "a")
        #expect(BlockedRequestMatch.request(for: try dialog("claude-02-c1-bash-blocked"), in: [request("b", "Bash", "touch")]) == nil)
    }

    @Test func filesMatchByNameAndFetchesByURL() throws {
        let edit = request("e", "Edit", "/work/probe/q.txt", kind: .fileEdit)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-22-c7-edit"), in: [edit])?.callID == "e")
        #expect(
            BlockedRequestMatch.request(
                for: try dialog("claude-22-c7-edit"), in: [request("w", "Edit", "/work/q.md", kind: .fileEdit)]) == nil)
        let fetch = request("f", "WebFetch", "https://example.com/", kind: .web)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [fetch])?.callID == "f")
    }

    @Test func questionsMatchByTheirText() throws {
        let colors = request(
            "q", "AskUserQuestion", "Which colors?\nWhich size?", kind: .question,
            questions: [ChatQuestion(text: "Which colors?"), ChatQuestion(text: "Which size?")])
        #expect(BlockedRequestMatch.request(for: try dialog("claude-08-c4-auq-q1"), in: [colors])?.callID == "q")
        let codex = request(
            "c", "request_user_input", "Pick a color", kind: .question, questions: [ChatQuestion(text: "Pick a color")])
        #expect(BlockedRequestMatch.request(for: try dialog("codex-04-x3-q1"), in: [codex])?.callID == "c")
    }

    @Test func aCodexCommandMatchesInsideItsScript() throws {
        let script = request("x", "exec", "await tools.exec_command({cmd: \"touch x1.txt\"})")
        #expect(BlockedRequestMatch.request(for: try dialog("codex-01-x1-exec"), in: [script])?.callID == "x")
        #expect(BlockedRequestMatch.request(for: try dialog("codex-01-x1-exec"), in: [request("y", "exec", "ls")]) == nil)
    }
}
