import Foundation
import SwiftUI
import Testing
import UIKit

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

    @Test func noEffectKeepsTheAnswersOffWhileTheDialogStaysAndNeverResends() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.progress == .unconfirmed)
        #expect(store.notice == "The Agent hasn't responded yet. Answer in the terminal if it stays.")
        #expect(store.canStop)

        // The same dialog: the key may still land, so a tap sends nothing.
        await store.refresh()
        #expect(store.progress == .unconfirmed)
        await store.perform(.choose(ordinal: 1))
        #expect(await pane.keys == [["1"]])

        // Another screen brings the answers back.
        await pane.show(try ScreenFixture.screen("claude-31-par-second"))
        await store.refresh()
        #expect(store.progress == .ready)
    }

    /// The next dialog can be identical (two `ls` approvals in a row): a
    /// call that waited resolving brings the answers back, one that only
    /// starts waiting does not.
    @Test func anUnconfirmedAnswerIsReleasedOnceAWaitingCallResolves() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        // A request the dialog doesn't match, as a subagent's dialog has.
        let waiting = Self.bash("toolu_x", "echo other")
        store.update(transcript: Self.transcript(pending: [waiting]))
        store.update(activity: .blocked)
        await store.refresh()
        await store.perform(.choose(ordinal: 1))
        #expect(store.progress == .unconfirmed)

        store.update(transcript: Self.transcript(pending: [waiting, Self.bash("toolu_y", "echo next")]))
        #expect(store.progress == .unconfirmed)
        store.update(transcript: Self.transcript(resolved: [waiting]))
        #expect(store.progress == .ready)
        await store.refresh()
        #expect(store.progress == .ready)
    }

    @Test func stopStillGoesAfterAnAnswerShowedNoEffect() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        await store.perform(.choose(ordinal: 1))
        #expect(store.progress == .unconfirmed)
        await pane.react(to: ["esc"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))

        await store.perform(.dismiss)

        #expect(await pane.keys == [["1"], ["esc"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    /// The key may have reached the pane: a read that shows another dialog, or
    /// none, says the failure is no longer about what the card shows.
    @Test(arguments: ["claude-31-par-second", "claude-01-ready"])
    func aKeyPadFailureGivesWayToWhatTheNextReadShows(next: String) async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let after = try ScreenFixture.screen(next)
        let store = BlockedCardStore(
            program: .claude,
            io: BlockedScreenIO(
                readScreen: { try await pane.read() },
                sendKeys: { _ in
                    await pane.show(after)
                    throw TransportError.channelFailed(detail: "timed out")
                },
                paste: { await pane.paste($0) }),
            clock: ManualClock().clock)
        store.update(activity: .blocked)
        await store.refresh()

        await store.sendKeys(["enter"])

        #expect(store.notice == nil)
    }

    /// The same dialog still shows, so the failure is about it.
    @Test func aKeyPadFailureStaysOverTheSameDialog() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = BlockedCardStore(
            program: .claude,
            io: BlockedScreenIO(
                readScreen: { try await pane.read() },
                sendKeys: { _ in throw TransportError.channelFailed(detail: "timed out") },
                paste: { await pane.paste($0) }),
            clock: ManualClock().clock)
        store.update(activity: .blocked)
        await store.refresh()

        await store.sendKeys(["enter"])

        #expect(store.notice?.hasPrefix("Heeler couldn't reach the Agent") == true)
    }

    @Test func aClaudeCardConfirmsByItsCallsResult() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let request = Self.bash("toolu_1", "touch c1.txt")
        let box = StoreBox()
        let store = BlockedCardStore(
            program: .claude,
            io: BlockedScreenIO(
                readScreen: { try await pane.read() },
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

    @Test func aPlanKeepsOnlyTheCardsStopSinceClaudeRecordsItsApproval() async throws {
        let request = ChatPendingRequest(
            entryID: ChatEntryID("plan"), callID: "toolu_plan", kind: .other, toolName: "ExitPlanMode", summary: "Plan")
        for (action, expected) in [
            (DialogAction.choose(ordinal: 1), ChatToolActivity.CardAnswer?.none),
            (.dismiss, .stopped),
        ] {
            let pane = FakePane(try ScreenFixture.screen("claude-16-c6-exitplan-1"))
            await pane.react(to: action == .dismiss ? ["esc"] : ["1"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
            let store = Self.store(.claude, pane: pane)
            store.update(transcript: Self.transcript(pending: [request]))
            store.update(activity: .blocked)
            await store.refresh()
            guard case .card(let card) = store.content else {
                Issue.record("Expected a plan card, got \(store.content)")
                return
            }
            #expect(card.dialog.kind == .claudePlan)

            await store.perform(action)

            #expect(store.progress == .ready, "\(action)")
            #expect(store.history.calls["toolu_plan"] == expected, "\(action)")
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

    /// Codex 0.162.1 delivers an asynchronous answer to a waiting tool call
    /// at once and draws no queued-messages notice: the next question
    /// replacing the answered one confirms the answer.
    @Test func aCodexAsynchronousAnswerWithoutTheNoticeConfirmsWhenTheQuestionLeaves() async throws {
        let pane = FakePane(try ScreenFixture.screen("codex-09-x4-expanded"))
        let notice = ["Messages to be submitted after next tool call", "↳ > Pick a fruit", "    Apple"]
        let delivered = try ScreenFixture.text("codex-10-x4-after-digit").components(separatedBy: "\r\n")
            .filter { row in !notice.contains { ANSIScreenDecoder.decode(row).rows.first?.text.contains($0) == true } }
        await pane.react(to: ["1"], with: ScreenFixture.synthetic(delivered))
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
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.history.queuedAnswers == ["item-1:0": "Apple"])
        guard case .card(let card) = store.content else {
            Issue.record("Expected the next question's card, got \(store.content)")
            return
        }
        #expect(card.dialog.title == "Pick a drink")
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

    /// Blocked with no dialog on screen, these programs' cards keep their
    /// sentence and key pad, even after a failed turn.
    @Test(arguments: [ChatProgram.claude, .codex, .pi, .omp])
    func otherProgramsKeepTheKeyPad(program: ChatProgram) async throws {
        let idle: [ChatProgram: String] = [
            .claude: "claude-01-ready", .codex: "codex-00-ready", .pi: "pi-06-empty-editor-119",
            .omp: "omp-08-empty-120-after-first",
        ]
        let pane = FakePane(try ScreenFixture.screen(try #require(idle[program])))
        let clock = ManualClock()
        let store = Self.store(program, pane: pane, clock: clock)
        store.update(transcript: Self.failedTurn("Provider error: connection refused"))
        store.update(activity: .blocked)
        clock.advance(.seconds(2))

        await store.refresh()

        #expect(program.offersKeysWhenBlockedWithoutDialog)
        #expect(store.content == .unreadable)
        #expect(store.unreadableNote == nil)
        #expect(await pane.keys.isEmpty)
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

    /// herdr reports Claude idle on its question review page and on a
    /// question with previews; the open call keeps the card reading.
    @Test func anIdleClaudeWithAnOpenQuestionStillShowsItsDialog() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-14-c4-review"))
        let store = Self.store(.claude, pane: pane)
        store.update(transcript: Self.transcript(pending: [Self.question("toolu_q")]))
        store.update(activity: .blocked)
        await store.refresh()
        store.update(activity: .idle)
        guard case .card(let review) = store.content else {
            Issue.record("Expected the review card to stay, got \(store.content)")
            return
        }
        #expect(review.dialog.kind == .claudeQuestionReview)

        // A relaunch: the review was reached while Chat wasn't watching.
        let relaunched = Self.store(.claude, pane: pane)
        relaunched.update(activity: .idle)
        relaunched.update(transcript: Self.transcript(pending: [Self.question("toolu_q")]))
        await relaunched.refresh()
        guard case .card(let card) = relaunched.content else {
            Issue.record("Expected the review card, got \(relaunched.content)")
            return
        }
        #expect(card.dialog.kind == .claudeQuestionReview)
        #expect(card.request?.callID == "toolu_q")

        await pane.show(try ScreenFixture.screen("claude-42-c8-phone-question-previews"))
        await relaunched.refresh()
        guard case .generic = relaunched.content else {
            Issue.record("Expected the generic card, got \(relaunched.content)")
            return
        }

        // The call's result ends it.
        relaunched.update(transcript: Self.transcript(resolved: [Self.question("toolu_q")]))
        #expect(relaunched.content == .none)
    }

    @Test func anIdleAgentWithoutAnOpenQuestionIsNotRead() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-14-c4-review"))
        let store = Self.store(.claude, pane: pane)
        store.update(transcript: Self.transcript(pending: [Self.bash("toolu_1", "touch c1.txt")]))
        store.update(activity: .idle)

        await store.refresh()

        #expect(store.content == .none)
        #expect(await pane.reads == 0)

        // Only Claude's idle questions read: herdr reports the others.
        let codex = Self.store(.codex, pane: pane)
        codex.update(transcript: Self.transcript(pending: [Self.question("toolu_q")]))
        codex.update(activity: .idle)
        await codex.refresh()
        #expect(codex.content == .none)
        #expect(await pane.reads == 0)
    }

    /// herdr 0.9.5 reports Codex's trust screen Idle once its question
    /// wraps, as on the phone's grid, and Codex reports no session before
    /// its first prompt.
    @Test func anIdleCodexAwaitingItsSessionShowsOnlyTheTrustScreen() async throws {
        let pane = FakePane(try ScreenFixture.screen("codex-22-x8-phone-trust-focus-quit"))
        let store = Self.store(.codex, pane: pane)
        store.update(activity: .idle)
        store.update(awaitingSession: true)

        await store.refresh()

        guard case .card(let card) = store.content else {
            Issue.record("Expected the trust card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .codexWorkspaceTrust)

        // Nothing else on an idle Codex's screen is a prompt to answer.
        for stem in ["codex-00-ready", "codex-01-x1-exec", "codex-15-x6-mcp-tool-list"] {
            await pane.show(try ScreenFixture.screen(stem))
            await store.refresh()
            #expect(store.content == .none, "\(stem)")
        }

        // Once Codex reports its session, an idle Codex isn't read.
        await pane.show(try ScreenFixture.screen("codex-22-x8-phone-trust-focus-quit"))
        await store.refresh()
        store.update(awaitingSession: false)
        #expect(store.content == .none)
        let reads = await pane.reads
        await store.refresh()
        #expect(await pane.reads == reads)
    }

    @Test func trustingAnIdleCodexWaitsForTheScreenToChange() async throws {
        let pane = FakePane(try ScreenFixture.screen("codex-22-x8-phone-trust-focus-quit"))
        await pane.react(to: ["up"], with: try ScreenFixture.screen("codex-21-x8-phone-trust"))
        let store = Self.store(.codex, pane: pane)
        store.update(activity: .idle)
        store.update(awaitingSession: true)
        await store.refresh()

        // Enter has not taken yet: the idle status alone confirms nothing.
        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["up"], ["enter"]])
        #expect(store.progress == .unconfirmed)

        await pane.react(to: ["enter"], with: try ScreenFixture.screen("codex-00-ready"))
        let retry = Self.store(.codex, pane: pane)
        retry.update(activity: .idle)
        retry.update(awaitingSession: true)
        await retry.refresh()

        await retry.perform(.choose(ordinal: 1))

        #expect(await pane.keys.suffix(1) == [["enter"]])
        #expect(retry.progress == .ready)
        #expect(retry.notice == nil)
        #expect(retry.content == .none)
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

    // MARK: Oh My Pi

    /// OMP ignores ctrl+q for 500 ms after drawing the approval, so the key
    /// waits until 650 ms after the panel first showed, and goes once.
    @Test func anOMPApprovalWaitsOutTheArmBeforeCtrlQ() async throws {
        let pane = FakePane(try ScreenFixture.screen("omp-24-approval-a-dialog"))
        await pane.react(to: ["ctrl+q"], with: try ScreenFixture.screen("omp-09-tool-working-3s"))
        let clock = ManualClock()
        let store = Self.store(.omp, pane: pane, clock: clock)
        let request = Self.ompBash("call_1|fc_1", "echo approved-2")
        store.update(transcript: Self.transcript(pending: [request]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .ompApproval)
        #expect(card.request?.callID == "call_1|fc_1")
        clock.advance(.milliseconds(100))

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["ctrl+q"]])
        // Seen at t0, tapped at t0 + 100 ms: the key went at t0 + 650 ms.
        #expect(clock.sleeps == [.milliseconds(550)])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.history.calls["call_1|fc_1"] == .allowed)
    }

    @Test func anOMPApprovalSeenLongAgoSendsAtOnce() async throws {
        let pane = FakePane(try ScreenFixture.screen("omp-24-approval-a-dialog"))
        await pane.react(to: ["ctrl+q"], with: try ScreenFixture.screen("omp-09-tool-working-3s"))
        let clock = ManualClock()
        let store = Self.store(.omp, pane: pane, clock: clock)
        store.update(activity: .blocked)
        await store.refresh()
        clock.advance(.seconds(2))

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["ctrl+q"]])
        #expect(clock.sleeps.isEmpty)
        #expect(store.progress == .ready)
    }

    /// Esc denies the call and OMP goes on; the transcript records the
    /// denial, so the card keeps nothing.
    @Test func anOMPDenyIsEscAndNotKeptAsAStop() async throws {
        let request = Self.ompBash("call_1|fc_1", "echo approved-2")
        for action in [DialogAction.dismiss, .choose(ordinal: 2)] {
            let pane = FakePane(try ScreenFixture.screen("omp-24-approval-a-dialog"))
            await pane.react(to: ["esc"], with: try ScreenFixture.screen("omp-24-approval-e-enter-deny-and-send"))
            let store = Self.store(.omp, pane: pane)
            store.update(transcript: Self.transcript(pending: [request]))
            store.update(activity: .blocked)
            await store.refresh()

            await store.perform(action)

            #expect(await pane.keys == [["esc"]], "\(action)")
            #expect(store.progress == .ready, "\(action)")
            #expect(store.composerFocusRequest == 0, "\(action)")
            #expect(store.history.isEmpty, "\(action)")
        }
    }

    /// Oh My Pi 18.12's session approval: ↓ to its row once the arm has
    /// passed, the pointer checked there, then Enter.
    @Test func anOMPSessionApprovalMovesToItsRowThenPressesEnter() async throws {
        let pane = FakePane(try ScreenFixture.screen("omp-36-approval-edit-18-12"))
        await pane.react(to: ["down"], with: try ScreenFixture.screen("omp-37-approval-session-a-after-down"))
        await pane.react(to: ["enter"], with: try ScreenFixture.screen("omp-09-tool-working-3s"))
        let clock = ManualClock()
        let store = Self.store(.omp, pane: pane, clock: clock)
        let request = ChatPendingRequest(
            entryID: ChatEntryID("call_e|fc_e"), callID: "call_e|fc_e", kind: .fileEdit, toolName: "edit",
            summary: "notes.txt")
        store.update(transcript: Self.transcript(pending: [request]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.option(2)?.label == "Approve edit for this session")
        #expect(card.request?.callID == "call_e|fc_e")

        await store.perform(.choose(ordinal: 2))

        #expect(await pane.keys == [["down"], ["enter"]])
        #expect(clock.sleeps.first == .milliseconds(650))
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.history.calls["call_e|fc_e"] == .allowed)
    }

    /// A ↓ that does not move the pointer stops the answer before Enter.
    @Test func anOMPSessionApprovalStopsWhenThePointerDoesNotMove() async throws {
        let pane = FakePane(try ScreenFixture.screen("omp-36-approval-edit-18-12"))
        let store = Self.store(.omp, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 2))

        #expect(await pane.keys == [["down"]])
        #expect(
            store.notice
                == "The dialog didn't respond the way Heeler expected, so it stopped. Finish here or in the terminal.")
        guard case .generic = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
    }

    @Test func anOMPPanelHeelerDoesNotKnowGetsTheGenericCardWithoutDigits() async throws {
        let pane = FakePane(try ScreenFixture.screen("omp-31-plan-review"))
        let store = Self.store(.omp, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        guard case .generic(let excerpt) = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
        #expect(excerpt.numbered.isEmpty)
        await store.press(number: 2)
        #expect(await pane.keys.isEmpty)
    }

    /// The program keeps drawing the question after Enter; the ask's result
    /// in the transcript confirms the answer.
    @Test func anOMPQuestionConfirmsByTheAskResult() async throws {
        let tui = FakeQuestionTUI(.omp, [Self.fruit])
        await tui.ignore("enter")
        let request = Self.ompAsk("call_a|fc_a", [Self.fruit])
        let box = StoreBox()
        let store = BlockedCardStore(
            program: .omp,
            io: BlockedScreenIO(
                readScreen: { await tui.read() },
                sendKeys: { keys in
                    await tui.send(keys)
                    guard keys == ["enter"] else { return }
                    await MainActor.run { box.store?.update(transcript: Self.transcript(resolved: [request])) }
                },
                paste: { await tui.paste($0) }),
            clock: ManualClock().clock)
        box.store = store
        store.update(transcript: Self.transcript(pending: [request]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .ompQuestion)
        #expect(card.request?.callID == "call_a|fc_a")

        await store.perform(.choose(ordinal: 2))

        #expect(await tui.keys == [["down"], ["enter"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    /// Each page is its own card: Enter answers it and turns to the next,
    /// and the review's Submit sends the answers.
    @Test func anOMPTwoQuestionAskAnswersEachPageThenSubmits() async throws {
        let questions = [Self.fruit, FakeQuestionTUI.Question(header: "size", text: "Pick a size", options: ["small", "large"])]
        let tui = FakeQuestionTUI(.omp, questions)
        let store = Self.store(tui)
        store.update(transcript: Self.transcript(pending: [Self.ompAsk("call_b", questions)]))
        store.update(activity: .blocked)
        await store.refresh()

        for (progress, ordinal) in [("fruit", 2), ("size", 1), ("Review answers", 1)] {
            guard case .card(let card) = store.content else {
                Issue.record("Expected a card on \(progress), got \(store.content)")
                return
            }
            #expect(card.dialog.progress == progress)
            #expect(card.request?.callID == "call_b", "\(progress)")
            await store.perform(.choose(ordinal: ordinal))
            #expect(store.progress == .ready, "\(progress)")
            #expect(store.notice == nil, "\(progress)")
        }

        #expect(await tui.keys == [["down"], ["enter"], ["enter"], ["enter"]])
        #expect(await tui.answers == ["pear", "small"])
        #expect(await tui.state == .submitted)
        #expect(store.content == .none)
    }

    @Test func aGuardedQuestionSendsNoKeysAndSaysWhy() async throws {
        let tui = FakeQuestionTUI(.omp, [Self.fruit])
        await tui.holdDraft("my draft text")
        let store = Self.store(tui)
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.focus.composerDraftGuard)

        await store.perform(.choose(ordinal: 1))

        #expect(await tui.keys.isEmpty)
        #expect(store.progress == .ready)
        #expect(
            store.notice
                == "Oh My Pi's input box holds a draft, so keys would go into it. Press Enter in the terminal to "
                + "queue it, or clear it, then answer.")

        // Stop still goes: Esc cancels the question.
        await store.perform(.dismiss)
        #expect(await tui.keys == [["esc"]])
        #expect(await tui.state == .cancelled)
        #expect(await tui.queued.isEmpty)
    }

    // MARK: Grok Build

    /// A digit approves at once. Grok Build records no approval, so the
    /// card keeps it, and the call's row reads Allowed.
    @Test func aGrokApprovalRecordsAllowedOnTheCall() async throws {
        let pane = FakePane(try ScreenFixture.screen("grok-12-permission-command"))
        await pane.react(to: ["3"], with: try ScreenFixture.screen("grok-03-working"))
        let store = Self.store(.grok, pane: pane)
        store.update(transcript: Self.transcript(pending: [Self.grokCommand("call-1", "chmod 644 README.md")]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .grokPermission)
        #expect(card.request?.callID == "call-1")

        await store.perform(.choose(ordinal: 2))

        #expect(await pane.keys == [["3"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.history.calls["call-1"] == .allowed)
    }

    /// The reject row's digit, from its button or from Stop. Grok Build's
    /// transcript records the rejection, so the card keeps nothing.
    @Test func aGrokDenyLeavesTheDeclineToTheTranscript() async throws {
        let request = Self.grokCommand("call-1", "chmod 644 README.md")
        for action in [DialogAction.dismiss, .choose(ordinal: 3)] {
            let pane = FakePane(try ScreenFixture.screen("grok-12-permission-command"))
            await pane.react(to: ["4"], with: try ScreenFixture.screen("grok-01-idle-empty"))
            let store = Self.store(.grok, pane: pane)
            store.update(transcript: Self.transcript(pending: [request]))
            store.update(activity: .blocked)
            await store.refresh()

            await store.perform(action)

            #expect(await pane.keys == [["4"]], "\(action)")
            #expect(store.progress == .ready, "\(action)")
            #expect(store.composerFocusRequest == 0, "\(action)")
            #expect(store.history.isEmpty, "\(action)")
        }
    }

    /// Parallel subagents with one description get identical cards, one
    /// after the other, and herdr stays Blocked between them, so approving
    /// the first shows no effect on screen. Grok Build writes
    /// `subagent_spawned` as the approved subagent starts, which can come
    /// in while the key's effect is checked: the second card's answers stay
    /// on. grok-44 is the second card as Grok drew it after the first's
    /// approval, its subagent running.
    @Test(arguments: [
        ("grok-35-permission-subagent-62", "Sleep 60 then reply done"),
        ("grok-44-permission-second-subagent-120", "Sleep 90 then done"),
    ])
    func aGrokSubagentStartingKeepsTheNextIdenticalCardAnswerable(stem: String, description: String) async throws {
        let first = Self.grokSpawn("call-1", description)
        let second = Self.grokSpawn("call-2", description)
        let pane = FakePane(try ScreenFixture.screen(stem))
        let box = StoreBox()
        let store = BlockedCardStore(
            program: .grok,
            io: BlockedScreenIO(
                readScreen: { try await pane.read() },
                sendKeys: { keys in
                    await pane.send(keys)
                    await MainActor.run {
                        box.store?.update(transcript: Self.transcript(pending: [second], running: [first]))
                    }
                },
                paste: { await pane.paste($0) }),
            clock: ManualClock().clock)
        box.store = store
        store.update(transcript: Self.transcript(pending: [first, second]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        let approve = try #require(card.dialog.options.first { $0.role == .approve }?.ordinal)
        #expect(card.dialog.options.contains { $0.role == .decline })

        await store.perform(.choose(ordinal: approve))

        #expect(await pane.keys == [["2"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        // The second card's Approve goes, as its Deny would.
        await store.perform(.choose(ordinal: approve))
        #expect(await pane.keys == [["2"], ["2"]])
    }

    /// Without a start the same answer stays unconfirmed, and a call that
    /// only starts waiting, as Grok writes the second spawn's call once the
    /// first runs, proves nothing. The first call starting later brings the
    /// answers back and drops the hint, also when the transcript shows it
    /// already resolved, as a quick command's would be.
    @Test(arguments: [false, true])
    func aGrokAnswerStaysUnconfirmedUntilACallThatWaitedStarts(alreadyResolved: Bool) async throws {
        let first = Self.grokSpawn("call-1", "Sleep 60 then reply done")
        let second = Self.grokSpawn("call-2", "Sleep 60 then reply done")
        let pane = FakePane(try ScreenFixture.screen("grok-35-permission-subagent-62"))
        let store = Self.store(.grok, pane: pane)
        store.update(transcript: Self.transcript(pending: [first]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        let approve = try #require(card.dialog.options.first { $0.role == .approve }?.ordinal)

        await store.perform(.choose(ordinal: approve))

        #expect(await pane.keys == [["2"]])
        #expect(store.progress == .unconfirmed)
        #expect(store.notice == "The Agent hasn't responded yet. Answer in the terminal if it stays.")
        store.update(transcript: Self.transcript(pending: [first, second]))
        await store.refresh()
        #expect(store.progress == .unconfirmed)
        await store.perform(.choose(ordinal: approve))
        #expect(await pane.keys == [["2"]])

        store.update(
            transcript: alreadyResolved
                ? Self.transcript(pending: [second], resolved: [first])
                : Self.transcript(pending: [second], running: [first]))

        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        await store.perform(.choose(ordinal: approve))
        #expect(await pane.keys == [["2"], ["2"]])
    }

    /// Only a call the card could be answering shows its answer took. The
    /// previous card's call can start late, or read as already done, after
    /// the next card's keys went out, which shows nothing about them; the
    /// next card's own call starting does. grok-44 follows grok-35 here as
    /// the card for another subagent.
    @Test(arguments: [false, true])
    func aGrokAnswerIgnoresThePreviousCardsCallStartingLate(alreadyResolved: Bool) async throws {
        let first = Self.grokSpawn("call-1", "Sleep 60 then reply done")
        let second = Self.grokSpawn("call-2", "Sleep 90 then done")
        let pane = FakePane(try ScreenFixture.screen("grok-35-permission-subagent-62"))
        await pane.react(to: ["2"], with: try ScreenFixture.screen("grok-44-permission-second-subagent-120"))
        let store = Self.store(.grok, pane: pane)
        store.update(transcript: Self.transcript(pending: [first, second]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        let approve = try #require(card.dialog.options.first { $0.role == .approve }?.ordinal)
        await store.perform(.choose(ordinal: approve))
        #expect(store.progress == .ready)
        guard case .card(let next) = store.content else {
            Issue.record("Expected the next card, got \(store.content)")
            return
        }
        #expect(next.dialog.title == "Allow Sleep 90 then done")

        await store.perform(.choose(ordinal: approve))
        #expect(await pane.keys == [["2"], ["2"]])
        #expect(store.progress == .unconfirmed)
        store.update(
            transcript: alreadyResolved
                ? Self.transcript(pending: [second], resolved: [first])
                : Self.transcript(pending: [second], running: [first]))

        #expect(store.progress == .unconfirmed)
        #expect(store.notice == "The Agent hasn't responded yet. Answer in the terminal if it stays.")
        await store.perform(.choose(ordinal: approve))
        #expect(await pane.keys == [["2"], ["2"]])
        store.update(transcript: Self.transcript(running: [first, second]))
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    /// A card that matches no waiting call, as when the transcript records
    /// its command otherwise, still has its answer brought back by any
    /// call that waited starting, as before calls were matched to cards.
    @Test func aGrokCardMatchingNoCallWaitsOnAnyCallThatWaited() async throws {
        let other = Self.grokCommand("call-1", "ls -la")
        let pane = FakePane(try ScreenFixture.screen("grok-12-permission-command"))
        let store = Self.store(.grok, pane: pane)
        store.update(transcript: Self.transcript(pending: [other]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.subject.command == "chmod 644 README.md")
        let approve = try #require(card.dialog.options.first { $0.role == .approve }?.ordinal)
        await store.perform(.choose(ordinal: approve))
        #expect(store.progress == .unconfirmed)

        store.update(transcript: Self.transcript(running: [other]))

        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    /// While herdr reports Blocked, a call Grok Build hasn't started reads
    /// as waiting, also one that needs no approval, so a command starting
    /// beside a subagent's card shows nothing about its answer. The spawn
    /// starting does.
    @Test func aGrokCommandStartingLeavesASubagentAnswerUnconfirmed() async throws {
        let spawn = Self.grokSpawn("call-1", "Sleep 60 then reply done")
        let command = Self.grokCommand("call-2", "git status")
        let pane = FakePane(try ScreenFixture.screen("grok-35-permission-subagent-62"))
        let store = Self.store(.grok, pane: pane)
        store.update(transcript: Self.transcript(pending: [spawn, command]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        let approve = try #require(card.dialog.options.first { $0.role == .approve }?.ordinal)
        await store.perform(.choose(ordinal: approve))
        #expect(store.progress == .unconfirmed)

        store.update(transcript: Self.transcript(pending: [spawn], running: [command]))

        #expect(store.progress == .unconfirmed)
        store.update(transcript: Self.transcript(running: [command, spawn]))
        #expect(store.progress == .ready)
    }

    /// Where Grok Build cut the card's question at its edge with `…`, the
    /// title still names its subagent by the description's start, with
    /// each run of whitespace read as one space, so another subagent's
    /// call starting leaves the answer unconfirmed.
    @Test(arguments: ["Sleep 60 then reply done", "Sleep 60  then\nreply done"])
    func aCutGrokSubagentCardWaitsOnItsOwnCall(description: String) async throws {
        let spawn = Self.grokSpawn("call-1", description)
        let other = Self.grokSpawn("call-2", "Sleep 90 then done")
        let pane = FakePane(try GrokCards.screen("synthetic-subagent-permission-40"))
        let store = Self.store(.grok, pane: pane)
        store.update(transcript: Self.transcript(pending: [other, spawn]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.title == "Allow Sleep 60 then reply d…")
        let approve = try #require(card.dialog.options.first { $0.role == .approve }?.ordinal)
        await store.perform(.choose(ordinal: approve))
        #expect(store.progress == .unconfirmed)

        store.update(transcript: Self.transcript(pending: [spawn], running: [other]))

        #expect(store.progress == .unconfirmed)
        store.update(transcript: Self.transcript(running: [other, spawn]))
        #expect(store.progress == .ready)
    }

    /// Only Grok Build writes a call's start once its card is answered.
    /// Claude Code's open calls read waiting or running from herdr's status
    /// alone, so one that reads running brings nothing back.
    @Test func outsideGrokBuildACallThatReadsRunningLeavesTheAnswerUnconfirmed() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        let waiting = Self.bash("toolu_x", "echo other")
        store.update(transcript: Self.transcript(pending: [waiting]))
        store.update(activity: .blocked)
        await store.refresh()
        await store.perform(.choose(ordinal: 1))
        #expect(store.progress == .unconfirmed)

        store.update(transcript: Self.transcript(running: [waiting]))

        #expect(store.progress == .unconfirmed)
    }

    // MARK: OpenCode

    /// The permission to read `.env` matches the session's read of it, not
    /// the command before it, so Reject goes as Esc. OpenCode records the
    /// rejection, so the card keeps nothing.
    @Test func anOpenCodePermissionMatchesItsPendingCall() async throws {
        let read = Self.openCodeRead("call_r", "/Users/developer/work/heeler-tmp-chat/opencode-a/project/.env")
        for action in [DialogAction.choose(ordinal: 3), .dismiss] {
            let pane = FakePane(try ScreenFixture.screen("opencode-10-permission-180"))
            await pane.react(to: ["esc"], with: try ScreenFixture.screen("opencode-08-working-180"))
            let store = Self.store(.opencode, pane: pane)
            store.update(transcript: Self.transcript(pending: [Self.bash("call_s", "ls -la"), read]))
            store.update(activity: .blocked)
            await store.refresh()
            guard case .card(let card) = store.content else {
                Issue.record("Expected a card, got \(store.content)")
                return
            }
            #expect(card.dialog.kind == .openCodePermission)
            #expect(card.request?.callID == "call_r")

            await store.perform(action)

            #expect(await pane.keys == [["esc"]], "\(action)")
            #expect(store.progress == .ready, "\(action)")
            #expect(store.notice == nil, "\(action)")
            #expect(store.composerFocusRequest == 0, "\(action)")
            #expect(store.history.isEmpty, "\(action)")
        }
    }

    /// Esc dismisses a matched question, and OpenCode records the dismissal
    /// ("The user dismissed this question"), so the card keeps nothing and
    /// the row shows the transcript's Declined.
    @Test func anOpenCodeQuestionDismissKeepsNoCardAnswer() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-13-question-180"))
        await pane.react(to: ["esc"], with: try ScreenFixture.screen("opencode-21-done-interrupted-180"))
        let store = Self.store(.opencode, pane: pane)
        let asked = ChatPendingRequest(
            entryID: ChatEntryID("call_q"), callID: "call_q", kind: .question, toolName: "question",
            summary: "Do you prefer red or blue?")
        store.update(transcript: Self.transcript(pending: [asked]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .openCodeQuestion)
        #expect(card.request?.callID == "call_q")

        await store.perform(.dismiss)

        #expect(await pane.keys == [["esc"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.history.isEmpty)
    }

    /// Right moves the fill to Always allow, checked there before Enter. A
    /// Right that leaves the fill where it was stops before Enter.
    @Test func alwaysAllowPassesItsFocusCheck() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-10-permission-180"))
        await pane.react(to: ["right"], with: try ScreenFixture.screen("opencode-11-permission-right1-180"))
        await pane.react(to: ["enter"], with: try ScreenFixture.screen("opencode-08-working-180"))
        let store = Self.store(.opencode, pane: pane)
        let read = Self.openCodeRead("call_r", "/Users/developer/work/heeler-tmp-chat/opencode-a/project/.env")
        store.update(transcript: Self.transcript(pending: [read]))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 2))

        #expect(await pane.keys == [["right"], ["enter"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.history.calls["call_r"] == .allowed)

        let stuck = FakePane(try ScreenFixture.screen("opencode-10-permission-180"))
        let stuckStore = Self.store(.opencode, pane: stuck)
        stuckStore.update(activity: .blocked)
        await stuckStore.refresh()

        await stuckStore.perform(.choose(ordinal: 2))

        #expect(await stuck.keys == [["right"]])
        #expect(
            stuckStore.notice
                == "The dialog didn't respond the way Heeler expected, so it stopped. Finish here or in the terminal.")
    }

    /// From Reject, Allow once is two Lefts away, each checked, then Enter.
    @Test func allowOnceFromRejectMovesTwiceAndConfirms() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-12-permission-right2-180"))
        await pane.react(
            to: ["left"],
            withEach: [
                try ScreenFixture.screen("opencode-11-permission-right1-180"),
                try ScreenFixture.screen("opencode-10-permission-180"),
            ])
        await pane.react(to: ["enter"], with: try ScreenFixture.screen("opencode-08-working-180"))
        let store = Self.store(.opencode, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["left"], ["left"], ["enter"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    /// OpenCode draws every shell command's permission alike but for its
    /// `$` line, so a tap on the card for `git status` sends nothing once
    /// the screen asks about `rm -rf build`.
    @Test func aShellCommandThatChangedBeforeTheTapGetsNoKeys() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-27-permission-shell-180"))
        let store = Self.store(.opencode, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        await pane.show(try ScreenFixture.screen("opencode-29-permission-shell-next-180"))

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys.isEmpty)
        #expect(store.notice == "This prompt changed. Check it before answering.")
        guard case .card(let card) = store.content else {
            Issue.record("Expected the next command's card, got \(store.content)")
            return
        }
        #expect(card.dialog.subject.command == "rm -rf build")
    }

    /// With Always allow focused in the terminal, OpenCode shows the rule
    /// in place of the command. A card that showed the command answers
    /// only once it shows the rule too.
    @Test func aCardAnswersOnlyTheLinesItShows() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-27-permission-shell-180"))
        await pane.react(to: ["enter"], with: try ScreenFixture.screen("opencode-08-working-180"))
        let store = Self.store(.opencode, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        await pane.show(try ScreenFixture.screen("opencode-28-permission-shell-right1-180"))

        await store.perform(.choose(ordinal: 2))

        #expect(await pane.keys.isEmpty)
        #expect(store.notice == "This prompt changed. Check it before answering.")
        guard case .card(let card) = store.content else {
            Issue.record("Expected the rule's card, got \(store.content)")
            return
        }
        #expect(card.dialog.subject.notes.last == "- git status *")

        await store.perform(.choose(ordinal: 2))
        #expect(await pane.keys == [["enter"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    /// After an answer OpenCode can show the next command's permission
    /// while herdr stays Blocked. Its `$` line confirms the answer, and a
    /// tap on it waits out the grace from when it showed.
    @Test func theNextShellCommandConfirmsTheAnswer() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-27-permission-shell-180"))
        await pane.react(to: ["enter"], with: try ScreenFixture.screen("opencode-29-permission-shell-next-180"))
        let clock = ManualClock()
        let store = Self.store(.opencode, pane: pane, clock: clock)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["enter"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        guard case .card(let card) = store.content else {
            Issue.record("Expected the next command's card, got \(store.content)")
            return
        }
        #expect(card.dialog.subject.command == "rm -rf build")

        let sleeps = clock.sleeps.count
        await pane.react(to: ["enter"], with: try ScreenFixture.screen("opencode-08-working-180"))
        await store.perform(.choose(ordinal: 1))
        #expect(await pane.keys == [["enter"], ["enter"]])
        #expect(clock.sleeps.dropFirst(sleeps).first == .milliseconds(150))
    }

    /// An answer that showed no effect keeps the answers off while its
    /// permission stays, and the next command's brings them back. After
    /// Always allow the answer's last read showed the rule, so the next
    /// command's rule tells it apart as well.
    @Test func theNextShellCommandReleasesAnUnconfirmedAnswer() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-27-permission-shell-180"))
        let store = Self.store(.opencode, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        await store.perform(.choose(ordinal: 1))
        #expect(await pane.keys == [["enter"]])
        #expect(store.progress == .unconfirmed)
        await store.refresh()
        #expect(store.progress == .unconfirmed)

        await pane.show(try ScreenFixture.screen("opencode-29-permission-shell-next-180"))
        await store.refresh()
        #expect(store.progress == .ready)
        #expect(store.notice == nil)

        let always = FakePane(try ScreenFixture.screen("opencode-27-permission-shell-180"))
        await always.react(to: ["right"], with: try ScreenFixture.screen("opencode-28-permission-shell-right1-180"))
        let alwaysStore = Self.store(.opencode, pane: always)
        alwaysStore.update(activity: .blocked)
        await alwaysStore.refresh()
        await alwaysStore.perform(.choose(ordinal: 2))
        #expect(await always.keys == [["right"], ["enter"]])
        #expect(alwaysStore.progress == .unconfirmed)
        await alwaysStore.refresh()
        #expect(alwaysStore.progress == .unconfirmed)

        // `rm -rf build`'s permission with Always allow focused.
        let rule = try ScreenFixture.text("opencode-28-permission-shell-right1-180")
        try #require(rule.components(separatedBy: "- git status *").count == 2)
        await always.show(ANSIScreenDecoder.decode(rule.replacingOccurrences(of: "- git status *", with: "- rm *        ")))
        await alwaysStore.refresh()
        #expect(alwaysStore.progress == .ready)
    }

    /// The next command's permission is a new dialog: the card unfolds,
    /// and a tap waits out the grace from when it showed.
    @Test func theNextShellCommandUnfoldsTheCardAndRestartsTheGrace() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-27-permission-shell-180"))
        await pane.react(to: ["enter"], with: try ScreenFixture.screen("opencode-08-working-180"))
        let clock = ManualClock()
        let store = Self.store(.opencode, pane: pane, clock: clock)
        store.update(activity: .blocked)
        await store.refresh()
        store.isCollapsed = true
        clock.advance(.seconds(5))

        await pane.show(try ScreenFixture.screen("opencode-29-permission-shell-next-180"))
        await store.refresh()
        #expect(!store.isCollapsed)

        await store.perform(.choose(ordinal: 1))
        #expect(await pane.keys == [["enter"]])
        #expect(clock.sleeps == [.milliseconds(150)])
        #expect(store.progress == .ready)
    }

    /// Always allow's focus swaps the command's line for the rule's on the
    /// same card; the next command's permission makes a new one.
    @Test func onlyTheNextShellCommandMakesANewCard() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-27-permission-shell-180"))
        let store = Self.store(.opencode, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        let card = store.dialogGeneration

        await pane.show(try ScreenFixture.screen("opencode-28-permission-shell-right1-180"))
        await store.refresh()
        #expect(store.dialogGeneration == card)
        await pane.show(try ScreenFixture.screen("opencode-27-permission-shell-180"))
        await store.refresh()
        #expect(store.dialogGeneration == card)

        await pane.show(try ScreenFixture.screen("opencode-29-permission-shell-next-180"))
        await store.refresh()
        #expect(store.dialogGeneration != card)
    }

    /// OpenCode's prompt would act on the key pad's keys, so a block with
    /// no dialog on screen gets a note in their place, once the quiet time
    /// has passed.
    @Test func anOpenCodeBlockWithoutADialogOffersNoKeys() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-02-session-empty-180"))
        let clock = ManualClock()
        let store = Self.store(.opencode, pane: pane, clock: clock)
        store.update(activity: .blocked)

        await store.refresh()
        #expect(store.content == .none)
        #expect(store.unreadableNote == nil)
        clock.advance(.seconds(2))
        await store.refresh()

        #expect(!ChatProgram.opencode.offersKeysWhenBlockedWithoutDialog)
        #expect(store.content == .unreadable)
        #expect(store.unreadableNote == Self.openCodeBlockedNote)
        #expect(await pane.keys.isEmpty)

        // A screen read that fails says the same.
        let unread = BlockedCardStore(program: .opencode, io: .unavailable, clock: clock.clock)
        unread.update(activity: .blocked)
        clock.advance(.seconds(2))
        await unread.refresh()
        #expect(unread.content == .unreadable)
        #expect(unread.unreadableNote == Self.openCodeBlockedNote)

        store.update(activity: .working)
        #expect(store.content == .none)
        #expect(store.unreadableNote == nil)
    }

    /// The panel draws in place of the prompt, and of a request waiting
    /// there, at any width. It comes first, even after a failed turn.
    @Test func aPanelOverTheRequestSaysToCloseIt() async throws {
        for stem in ["opencode-15-subagent-panel-180", "opencode-41-subagent-panel-62"] {
            let pane = FakePane(try ScreenFixture.screen(stem))
            let clock = ManualClock()
            let store = Self.store(.opencode, pane: pane, clock: clock)
            store.update(transcript: Self.failedTurn("Provider error: connection refused"))
            store.update(activity: .blocked)
            clock.advance(.seconds(2))

            await store.refresh()

            #expect(store.content == .unreadable, "\(stem)")
            #expect(
                store.unreadableNote
                    == "OpenCode's subagent panel covers its request. Close the panel in the terminal to answer it.",
                "\(stem)")
            #expect(await pane.keys.isEmpty, "\(stem)")
        }
    }

    /// herdr reports OpenCode Blocked when a model request fails. The note
    /// quotes the failure: the newest turn's ending, or an error it shows
    /// before the turn ends. A failure in an earlier turn says nothing.
    @Test func aFailedTurnExplainsTheBlock() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-02-session-empty-180"))
        let clock = ManualClock()
        let store = Self.store(.opencode, pane: pane, clock: clock)
        store.update(transcript: Self.failedTurn("Provider error: connection refused"))
        store.update(activity: .blocked)
        clock.advance(.seconds(2))

        await store.refresh()

        #expect(store.content == .unreadable)
        #expect(
            store.unreadableNote
                == "OpenCode stopped with an error: Provider error: connection refused. herdr holds Chat's messages "
                + "while it reports Blocked, so continue in the terminal.")

        // A step's error, before the row that ends the turn.
        var open = Self.failedTurn("Rate limit reached.\n  Retry later.")
        open.turns[0].ending = nil
        store.update(transcript: open)
        await store.refresh()
        #expect(
            store.unreadableNote
                == "OpenCode stopped with an error: Rate limit reached. Retry later. herdr holds Chat's messages "
                + "while it reports Blocked, so continue in the terminal.")

        // A question or an exclamation ends the sentence by itself, as
        // OpenCode 2.0.32 words a refused connection.
        for failure in [
            "ConnectionRefused: Unable to connect. Is the computer able to access the url?",
            "Quota exhausted!",
        ] {
            store.update(transcript: Self.failedTurn(failure))
            await store.refresh()
            #expect(
                store.unreadableNote
                    == "OpenCode stopped with an error: \(failure) herdr holds Chat's messages while it reports "
                    + "Blocked, so continue in the terminal.")
        }

        // A long error is cut, and its ellipsis ends the sentence.
        store.update(transcript: Self.failedTurn(String(repeating: "x", count: 300)))
        await store.refresh()
        #expect(
            store.unreadableNote
                == "OpenCode stopped with an error: \(String(repeating: "x", count: 200))… herdr holds Chat's "
                + "messages while it reports Blocked, so continue in the terminal.")

        // The next turn opened, and has shown no error.
        var next = Self.failedTurn("Provider error: connection refused")
        let prompt = ChatEntryID("oc:msg_next")
        next.entries.append(
            ChatEntry(id: prompt, sourceOffset: 3, content: .user(ChatUserMessage(text: "Reply with the word kiwi"))))
        next.turns.append(ChatTurn(firstEntryID: prompt))
        store.update(transcript: next)
        await store.refresh()
        #expect(store.unreadableNote == Self.openCodeBlockedNote)
    }

    /// The reject-feedback stage is a dialog Heeler doesn't answer: its
    /// excerpt shows what the keys would answer, so the pad stays.
    @Test func anUnrecognizedOpenCodeDialogKeepsTheKeyPad() async throws {
        let pane = FakePane(try ScreenFixture.screen("opencode-25-reject-feedback-180"))
        let clock = ManualClock()
        let store = Self.store(.opencode, pane: pane, clock: clock)
        store.update(transcript: Self.failedTurn("Provider error: connection refused"))
        store.update(activity: .blocked)
        clock.advance(.seconds(2))

        await store.refresh()

        guard case .generic = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
        #expect(store.unreadableNote == nil)
        await store.sendKeys(["esc"])
        #expect(await pane.keys == [["esc"]])
    }

    // MARK: Antigravity CLI

    /// herdr 0.9.5 reports agy idle under its file dialogs, a command's
    /// note field and a question's answer field; an open call that asks
    /// the user stands in for Blocked there.
    @Test(arguments: [
        ("agy-47-perm-file-edit-default-120x40", BlockedDialogKind.agyFileEdit, "agy:5:tool:0"),
        ("agy-99-perm-file-create-default-62x41", .agyFileCreate, "agy:6:tool:0"),
        ("agy-109-perm-run-command-amend-62x41", .agyCommand, "agy:7:tool:0"),
        ("agy-104-ask-question-writein-after-digit-62x41", .agyQuestion, "agy:8:tool:0"),
    ])
    func anIdleAgyWithAnOpenCallThatAsksShowsItsDialog(stem: String, kind: BlockedDialogKind, callID: String)
        async throws
    {
        let pane = FakePane(try ScreenFixture.screen(stem))
        let store = Self.store(.agy, pane: pane)
        let requests = [
            Self.agyCall("agy:5:tool:0", "replace_file_content", .fileEdit, "/Users/developer/projects/fruits/fruits.txt"),
            Self.agyCall("agy:6:tool:0", "write_to_file", .fileWrite, "/Users/developer/projects/fruits2/a3note.txt"),
            Self.agyCall("agy:7:tool:0", "run_command", .command, "echo a3-hi"),
            Self.agyCall("agy:8:tool:0", "ask_question", .question, "Which pet do you prefer?"),
        ]
        // An idle agy's command row reads `no result`, its call still open.
        store.update(transcript: Self.agyTranscript(open: requests, status: .noResult))
        store.update(activity: .idle)

        await store.refresh()

        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == kind)
        #expect(card.request?.callID == callID)
    }

    /// agy under `NO_COLOR` draws the same dialogs without colors, herdr
    /// reports its file creation idle, and the open call stands in for
    /// Blocked there as it does in agy's colors. The file dialogs cut the
    /// path at 92 columns, so the call's whole path matches by its start.
    @Test(arguments: [
        ("agy-139-nocolor-perm-file-create-92x47", BlockedDialogKind.agyFileCreate),
        ("agy-141-nocolor-perm-file-edit-92x47", .agyFileEdit),
        ("agy-135-nocolor-perm-run-command-92x47", .agyCommand),
        ("agy-144-nocolor-ask-question-multi-q1-92x47", .agyQuestion),
        ("agy-148-nocolor-ask-question-multiselect-92x47", .agyQuestion),
    ])
    func anIdleColorlessAgyWithAnOpenCallThatAsksShowsItsDialog(stem: String, kind: BlockedDialogKind) async throws {
        let pane = FakePane(try ScreenFixture.screen(stem))
        let store = Self.store(.agy, pane: pane)
        let call = try #require(Self.colorlessCalls[stem])
        store.update(transcript: Self.agyTranscript(open: [call], status: .noResult))
        store.update(activity: .idle)

        await store.refresh()

        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == kind)
        #expect(card.request?.callID == call.callID)
    }

    /// The open call each colorless dialog asks for.
    private static let colorlessCalls: [String: ChatPendingRequest] = {
        let file =
            "/Users/developer/projects/heeler-acceptance/mac-core-2026-11-08/no-color-captures-agy-153-"
            + "herdr095workspaceprobefolder/agy-research/probe-b/proj2/nc.txt"
        return [
            "agy-139-nocolor-perm-file-create-92x47": agyCall("agy:10:tool:0", "write_to_file", .fileWrite, file),
            "agy-141-nocolor-perm-file-edit-92x47": agyCall("agy:11:tool:0", "replace_file_content", .fileEdit, file),
            "agy-135-nocolor-perm-run-command-92x47": agyCall(
                "agy:12:tool:0", "run_command", .command, "echo nc-check"),
            "agy-144-nocolor-ask-question-multi-q1-92x47": agyCall(
                "agy:13:tool:0", "ask_question", .question, "Which color?"),
            "agy-148-nocolor-ask-question-multiselect-92x47": agyCall(
                "agy:14:tool:0", "ask_question", .question, "Which fruits do you like?"),
        ]
    }()

    /// The trust prompt under `NO_COLOR` shows before agy reports a session,
    /// which an idle agy is read for alone.
    @Test func anIdleColorlessAgyAwaitingItsSessionShowsTheTrustPrompt() async throws {
        let pane = FakePane(try ScreenFixture.screen("agy-152-nocolor-trust-prompt-92x47"))
        let store = Self.store(.agy, pane: pane)
        store.update(activity: .idle)
        store.update(awaitingSession: true)

        await store.refresh()

        guard case .card(let card) = store.content else {
            Issue.record("Expected the trust card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .agyWorkspaceTrust)
    }

    /// Without an open call that asks, an idle agy isn't read: a read or a
    /// command sent to the background has no dialog.
    @Test func anIdleAgyWithoutAnOpenCallThatAsksIsNotRead() async throws {
        let pane = FakePane(try ScreenFixture.screen("agy-47-perm-file-edit-default-120x40"))
        let store = Self.store(.agy, pane: pane)
        store.update(
            transcript: Self.agyTranscript(
                open: [Self.agyCall("agy:3:tool:0", "view_file", .fileRead, "/Users/developer/projects/fruits/a.txt")],
                status: .noResult))
        store.update(activity: .idle)
        await store.refresh()
        #expect(store.content == .none)
        #expect(await pane.reads == 0)

        // A command in the background has its result, so the reducer offers
        // no request for it.
        let background = Self.agyCall("agy:4:tool:0", "run_command", .command, "sleep 40")
        var transcript = Self.agyTranscript(open: [background], status: .started)
        transcript.pendingRequests = []
        store.update(transcript: transcript)
        await store.refresh()
        #expect(store.content == .none)
        #expect(await pane.reads == 0)

        // Another program's idle open call reads nothing either.
        let grok = Self.store(.grok, pane: pane)
        grok.update(transcript: Self.agyTranscript(open: [background], status: .noResult))
        grok.update(activity: .idle)
        await grok.refresh()
        #expect(await pane.reads == 0)
    }

    /// The card's answer waits on the call: a re-read in which the idle
    /// command's row reads `no result` releases nothing, its result does.
    @Test func anAgyAnswerThatShowedNoEffectWaitsForItsCallsResult() async throws {
        let pane = FakePane(try ScreenFixture.screen("agy-108-perm-run-command-62x41"))
        let clock = ManualClock()
        let store = Self.store(.agy, pane: pane, clock: clock)
        let command = Self.agyCall("agy:7:tool:0", "run_command", .command, "echo a3-hi")
        store.update(transcript: Self.agyTranscript(open: [command], status: .awaitingApproval))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.progress == .unconfirmed)
        store.update(activity: .idle)
        store.update(transcript: Self.agyTranscript(open: [command], status: .noResult))
        #expect(store.progress == .unconfirmed)

        var resolved = Self.agyTranscript(open: [command], status: .succeeded)
        resolved.pendingRequests = []
        store.update(transcript: resolved)
        #expect(store.progress == .ready)
        #expect(store.content == .none)
    }

    /// Esc on a permission stops the turn and agy records nothing, so the
    /// card keeps the stop; Esc on a question skips it, which agy records.
    @Test func anAgyStopIsKeptAndASkipIsNot() async throws {
        let pane = FakePane(try ScreenFixture.screen("agy-108-perm-run-command-62x41"))
        await pane.react(to: ["esc"], with: try ScreenFixture.screen("agy-02-idle-empty-120x40"))
        let store = Self.store(.agy, pane: pane)
        let command = Self.agyCall("agy:7:tool:0", "run_command", .command, "echo a3-hi")
        store.update(transcript: Self.agyTranscript(open: [command], status: .awaitingApproval))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.dismiss)

        #expect(await pane.keys == [["esc"]])
        #expect(store.progress == .ready)
        #expect(store.composerFocusRequest == 1)
        #expect(store.history.calls == ["agy:7:tool:0": .stopped])

        await pane.show(try ScreenFixture.screen("agy-41-ask-question-single-120x40"))
        let question = Self.agyCall("agy:9:tool:0", "ask_question", .question, "Which fruit do you prefer?")
        let asker = Self.store(.agy, pane: pane)
        asker.update(transcript: Self.agyTranscript(open: [question], status: .awaitingApproval))
        asker.update(activity: .blocked)
        await asker.refresh()

        await asker.perform(.dismiss)

        #expect(await pane.keys.suffix(1) == [["esc"]])
        #expect(asker.progress == .ready)
        #expect(asker.composerFocusRequest == 0)
        #expect(asker.history.isEmpty)
    }

    /// Two questions filled in on the card: the first page's digit turns
    /// to the second, whose digit answers both.
    @Test func anAgyTwoQuestionFormAnswersEachPage() async throws {
        let pane = FakePane(try ScreenFixture.screen("agy-44-ask-question-multi-120x40"))
        await pane.react(to: ["2"], with: try ScreenFixture.screen("agy-45-ask-question-multi-q2-120x40"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("agy-02-idle-empty-120x40"))
        let store = Self.store(.agy, pane: pane)
        var ask = Self.agyCall("agy:9:tool:0", "ask_question", .question, "What is your favorite color?")
        ask.questions = [
            ChatQuestion(text: "What is your favorite color?", options: ["Red", "Blue"].map { .init(label: $0) }),
            ChatQuestion(text: "What is your favorite season?", options: ["Summer", "Winter"].map { .init(label: $0) }),
        ]
        store.update(transcript: Self.agyTranscript(open: [ask], status: .awaitingApproval))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content, QuestionForm(card: card) != nil else {
            Issue.record("Expected a form, got \(store.content)")
            return
        }

        await store.submit([.option(1), .option(0)])

        #expect(await pane.keys == [["2"], ["1"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.content == .none)
    }

    /// agy writes a call's result only once it has run, and can draw the
    /// next dialog first: a second edit of the same file. The answered call
    /// stays out of that card's match until the transcript resolves it.
    @Test func anAnsweredAgyCallNeverStandsInForTheNextDialog() async throws {
        let first = try ScreenFixture.text("agy-47-perm-file-edit-default-120x40")
        let padded = "date" + String(repeating: " ", count: 108)
        try #require(first.contains(padded))
        let second = first.replacingOccurrences(of: padded, with: "fig" + String(repeating: " ", count: 109))
        let pane = FakePane(ANSIScreenDecoder.decode(first))
        await pane.react(to: ["1"], with: ANSIScreenDecoder.decode(second))
        let store = Self.store(.agy, pane: pane)
        let path = "/Users/developer/projects/fruits/fruits.txt"
        let date = Self.agyCall("agy:24:tool:0", "edit_file", .fileEdit, path)
        let fig = Self.agyCall("agy:24:tool:1", "edit_file", .fileEdit, path)
        store.update(transcript: Self.agyTranscript(open: [date, fig], status: .awaitingApproval))
        store.update(activity: .idle)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.request?.callID == "agy:24:tool:0")

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        guard case .card(let next) = store.content else {
            Issue.record("Expected the next card, got \(store.content)")
            return
        }
        #expect(next.dialog.body.last == "2  +  fig")
        #expect(next.request?.callID == "agy:24:tool:1")
        await store.refresh()
        guard case .card(let refreshed) = store.content else { return }
        #expect(refreshed.request?.callID == "agy:24:tool:1")

        // Once the transcript resolves it, the call no longer waits at all.
        store.update(transcript: Self.agyTranscript(open: [fig], status: .awaitingApproval))
        await store.refresh()
        guard case .card(let resolved) = store.content else { return }
        #expect(resolved.request?.callID == "agy:24:tool:1")
    }

    /// A dialog answered in the terminal or another client leaves its call
    /// open too, until agy writes the result, and agy can draw the next
    /// dialog first: a second edit of the same file. That card takes its
    /// own call, so its answer is kept under that call, and the line the
    /// screen cut never shows the first call's change.
    @Test func anAgyCallAnsweredInTheTerminalNeverStandsInForTheNextDialog() async throws {
        let date = try BlockedRequestMatchTests.agyEditCall()
        let fig = Self.agyCall("agy:24:tool:1", "edit_file", .fileEdit, date.summary)
        let pane = FakePane(try ScreenFixture.screen("agy-47-perm-file-edit-default-120x40"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("agy-02-idle-empty-120x40"))
        let store = Self.store(.agy, pane: pane)
        store.update(transcript: Self.agyTranscript(open: [date, fig], status: .awaitingApproval))
        store.update(activity: .idle)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.request?.callID == "agy:24:tool:0")

        // Answered in the terminal: the next edit's dialog, its added line
        // cut at the screen's edge.
        let cut = "fig " + String(repeating: "x", count: 120)
        await pane.show(try Self.agyEdit("agy-47-perm-file-edit-default-120x40", width: 120, adding: cut))
        await store.refresh()
        guard case .card(let next) = store.content else {
            Issue.record("Expected the next card, got \(store.content)")
            return
        }
        #expect(next.dialog.subject.changesAreCut)
        #expect(next.request?.callID == "agy:24:tool:1")
        #expect(BlockedRequestMatch.agyChanges(on: next.dialog, call: next.request) == Array(next.dialog.body.dropFirst()))

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.history.calls == ["agy:24:tool:1": .allowed])
    }

    /// A read can miss a dialog that still waits: it fails, or catches a
    /// redraw without the dialog or with one Heeler can't read, or the pane
    /// was resized and cut the dialog's changed line at its new edge. None
    /// of these lets the next call take the dialog's card, and a call left
    /// out of another dialog's card takes its own dialog again.
    @Test func aWaitingAgyCallKeepsItsDialogThroughReadsThatMissIt() async throws {
        let path = "/Users/developer/projects/fruits/fruits.txt"
        let line = "date and a line long enough to be cut at forty columns"
        let wide = try Self.agyEdit("agy-47-perm-file-edit-default-120x40", width: 120, adding: line)
        let narrow = try Self.agyEdit("agy-48-perm-file-edit-default-40x30", width: 40, adding: line)
        let next = try Self.agyEdit("agy-47-perm-file-edit-default-120x40", width: 120, adding: "fig")
        let text = try ScreenFixture.text("agy-47-perm-file-edit-default-120x40")
        try #require(text.contains("Pending edit"))
        let unknown = ANSIScreenDecoder.decode(text.replacingOccurrences(of: "Pending edit", with: "Pending edits"))
        let pane = FakePane(wide)
        let store = Self.store(.agy, pane: pane)
        let first = "agy:24:tool:0"
        let second = "agy:24:tool:1"
        store.update(
            transcript: Self.agyTranscript(
                open: [Self.agyCall(first, "edit_file", .fileEdit, path), Self.agyCall(second, "edit_file", .fileEdit, path)],
                status: .awaitingApproval))
        store.update(activity: .idle)
        func shownCall(_ screen: ANSIScreen) async -> String? {
            await pane.show(screen)
            await store.refresh()
            guard case .card(let card) = store.content else { return nil }
            return card.request?.callID
        }
        #expect(await shownCall(wide) == first)

        let shown = store.content
        await pane.failReads(true)
        await store.refresh()
        await pane.failReads(false)
        #expect(store.content == shown)
        #expect(await shownCall(wide) == first)

        await pane.show(try ScreenFixture.screen("agy-02-idle-empty-120x40"))
        await store.refresh()
        #expect(store.content == .none)
        #expect(await shownCall(wide) == first)

        await pane.show(unknown)
        await store.refresh()
        guard case .generic = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
        #expect(await shownCall(wide) == first)

        #expect(await shownCall(narrow) == first)
        guard case .card(let resized) = store.content else { return }
        #expect(resized.dialog.subject.changesAreCut)
        let whole = try #require(AgyDialogParser.parse(wide).dialog)
        #expect(resized.dialog.fingerprint != whole.fingerprint)
        #expect(await shownCall(wide) == first)

        #expect(await shownCall(next) == second)
        #expect(await shownCall(wide) == first)
    }

    /// A call keeps the read of its dialog that cut the least: read at 40
    /// columns and then at 62, both cutting the added line, its card keeps
    /// the wider read. Answered in the terminal, the next edit's dialog,
    /// whose line differs past the 40-column cut, takes its own call.
    @Test func anAgyCallKeepsTheReadOfItsDialogThatCutTheLeast() async throws {
        let path = "/Users/developer/projects/fruits/fruits.txt"
        let line = "date and a line long enough to be cut at forty columns and at sixty-two"
        let narrow = try Self.agyEdit("agy-48-perm-file-edit-default-40x30", width: 40, adding: line)
        let wider = try Self.agyEdit("agy-48-perm-file-edit-default-62x41", width: 62, adding: line)
        let next = try Self.agyEdit(
            "agy-48-perm-file-edit-default-62x41", width: 62,
            adding: line.replacingOccurrences(of: "forty", with: "fifty"))
        let pane = FakePane(narrow)
        let store = Self.store(.agy, pane: pane)
        let first = "agy:24:tool:0"
        let second = "agy:24:tool:1"
        store.update(
            transcript: Self.agyTranscript(
                open: [Self.agyCall(first, "edit_file", .fileEdit, path), Self.agyCall(second, "edit_file", .fileEdit, path)],
                status: .awaitingApproval))
        store.update(activity: .idle)
        func shownCall(_ screen: ANSIScreen) async -> String? {
            await pane.show(screen)
            await store.refresh()
            guard case .card(let card) = store.content else { return nil }
            return card.request?.callID
        }

        #expect(await shownCall(narrow) == first)
        #expect(await shownCall(wider) == first)
        guard case .card(let resized) = store.content else { return }
        #expect(resized.dialog.subject.changesAreCut)

        #expect(await shownCall(next) == second)
        #expect(await shownCall(wider) == first)
    }

    /// An answer the card sent that showed no effect may still land, so
    /// its call keeps the dialog's card while it stays, and the next
    /// dialog takes its own call once it shows.
    @Test func anAgyAnswerThatShowedNoEffectKeepsItsCallOnItsDialogAlone() async throws {
        let path = "/Users/developer/projects/fruits/fruits.txt"
        let pane = FakePane(try ScreenFixture.screen("agy-47-perm-file-edit-default-120x40"))
        let store = Self.store(.agy, pane: pane)
        store.update(
            transcript: Self.agyTranscript(
                open: [
                    Self.agyCall("agy:24:tool:0", "edit_file", .fileEdit, path),
                    Self.agyCall("agy:24:tool:1", "edit_file", .fileEdit, path),
                ],
                status: .awaitingApproval))
        store.update(activity: .idle)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.progress == .unconfirmed)
        await store.refresh()
        guard case .card(let waiting) = store.content else {
            Issue.record("Expected the card, got \(store.content)")
            return
        }
        #expect(waiting.request?.callID == "agy:24:tool:0")

        await pane.show(try Self.agyEdit("agy-47-perm-file-edit-default-120x40", width: 120, adding: "fig"))
        await store.refresh()
        #expect(store.progress == .ready)
        guard case .card(let next) = store.content else {
            Issue.record("Expected the next card, got \(store.content)")
            return
        }
        #expect(next.request?.callID == "agy:24:tool:1")
    }

    /// Skip on the form's second page goes out on the second page: the
    /// first question gets its digit, never Esc, and Esc on the last page
    /// submits the set (agy-46 records the season `(skipped)`).
    @Test func anAgyFormSkipsTheLaterPageItWasTappedOn() async throws {
        let pane = FakePane(try ScreenFixture.screen("agy-44-ask-question-multi-120x40"))
        await pane.react(to: ["2"], with: try ScreenFixture.screen("agy-45-ask-question-multi-q2-120x40"))
        await pane.react(to: ["esc"], with: try ScreenFixture.screen("agy-46-ask-question-multi-after-esc-120x40"))
        let store = try await Self.agyColorAndSeasonForm(on: pane)

        await store.submit([.option(1), .skipped])

        #expect(await pane.keys == [["2"], ["esc"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.content == .none)
    }

    /// A skipped first page sends Esc there, checks the second page shows,
    /// then answers it.
    @Test func anAgyFormSkipsItsFirstPageInTurn() async throws {
        let pane = FakePane(try ScreenFixture.screen("agy-44-ask-question-multi-120x40"))
        await pane.react(to: ["esc"], with: try ScreenFixture.screen("agy-45-ask-question-multi-q2-120x40"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("agy-02-idle-empty-120x40"))
        let store = try await Self.agyColorAndSeasonForm(on: pane)

        await store.submit([.skipped, .option(0)])

        #expect(await pane.keys == [["esc"], ["1"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    /// herdr reports agy's trust prompt idle at 40 columns, before agy
    /// reports a session; nothing else on such a screen is read as a dialog.
    @Test func anIdleAgyAwaitingItsSessionShowsOnlyTheTrustPrompt() async throws {
        let pane = FakePane(try ScreenFixture.screen("agy-12-trust-prompt-no-selected-40x30"))
        let store = Self.store(.agy, pane: pane)
        store.update(activity: .idle)
        store.update(awaitingSession: true)

        await store.refresh()

        guard case .card(let card) = store.content else {
            Issue.record("Expected the trust card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .agyWorkspaceTrust)

        await pane.show(try ScreenFixture.screen("agy-47-perm-file-edit-default-120x40"))
        await store.refresh()
        #expect(store.content == .none)

        store.update(awaitingSession: false)
        let reads = await pane.reads
        await store.refresh()
        #expect(await pane.reads == reads)
    }

    // MARK: Helpers

    private static let openCodeBlockedNote =
        "OpenCode reports Blocked, but its screen shows no question. This usually means the model request failed. "
        + "Check the terminal."

    private static let fruit = FakeQuestionTUI.Question(
        header: "fruit", text: "Pick a fruit", options: ["apple", "pear", "plum"])

    private static func ompAsk(_ id: String, _ questions: [FakeQuestionTUI.Question]) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: .question, toolName: "ask",
            summary: questions.first?.text ?? "",
            questions: questions.map {
                ChatQuestion(id: $0.header, text: $0.text, options: $0.options.map { ChatQuestion.Option(label: $0) })
            })
    }

    private static func store(_ tui: FakeQuestionTUI) -> BlockedCardStore {
        BlockedCardStore(
            program: tui.program,
            io: BlockedScreenIO(
                readScreen: { await tui.read() },
                sendKeys: { await tui.send($0) },
                paste: { await tui.paste($0) }),
            clock: ManualClock().clock)
    }

    private static func grokCommand(_ id: String, _ command: String) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: .command, toolName: "run_terminal_command", summary: command)
    }

    /// A subagent's spawn while its card waits: its title is the
    /// description the card asks about.
    private static func grokSpawn(_ id: String, _ description: String) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: .agent, toolName: "spawn_subagent", summary: description)
    }

    private static func ompBash(_ id: String, _ command: String) -> ChatPendingRequest {
        ChatPendingRequest(entryID: ChatEntryID(id), callID: id, kind: .command, toolName: "bash", summary: command)
    }

    private static func openCodeRead(_ id: String, _ path: String) -> ChatPendingRequest {
        ChatPendingRequest(entryID: ChatEntryID(id), callID: id, kind: .fileRead, toolName: "read", summary: path)
    }

    private static func store(_ program: ChatProgram, pane: FakePane, clock: ManualClock = ManualClock()) -> BlockedCardStore {
        BlockedCardStore(
            program: program,
            io: BlockedScreenIO(
                readScreen: { try await pane.read() },
                sendKeys: { await pane.send($0) },
                paste: { await pane.paste($0) }),
            clock: clock.clock)
    }

    /// A store showing agy-44's two questions as a form.
    private static func agyColorAndSeasonForm(on pane: FakePane) async throws -> BlockedCardStore {
        let store = Self.store(.agy, pane: pane)
        var ask = Self.agyCall("agy:9:tool:0", "ask_question", .question, "What is your favorite color?")
        ask.questions = [
            ChatQuestion(text: "What is your favorite color?", options: ["Red", "Blue"].map { .init(label: $0) }),
            ChatQuestion(text: "What is your favorite season?", options: ["Summer", "Winter"].map { .init(label: $0) }),
        ]
        store.update(transcript: Self.agyTranscript(open: [ask], status: .awaitingApproval))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return store
        }
        _ = try #require(QuestionForm(card: card))
        return store
    }

    /// agy's edit dialog captured in `stem`, a pane `width` cells wide,
    /// adding `line` where it added `date`: padded to the dialog's edge, or
    /// cut there as agy cuts a long line.
    private static func agyEdit(_ stem: String, width: Int, adding line: String) throws -> ANSIScreen {
        let text = try ScreenFixture.text(stem)
        // `  2  +  ` leads the row.
        let room = width - 8
        let date = "date" + String(repeating: " ", count: room - 4)
        try #require(text.contains(date))
        let shown = String(line.prefix(room))
        return ANSIScreenDecoder.decode(
            text.replacingOccurrences(of: date, with: shown + String(repeating: " ", count: room - shown.count)))
    }

    private static func agyCall(
        _ id: String, _ tool: String, _ kind: ChatToolActivity.Kind, _ summary: String
    ) -> ChatPendingRequest {
        ChatPendingRequest(entryID: ChatEntryID(id), callID: id, kind: kind, toolName: tool, summary: summary)
    }

    /// agy's calls in one open turn, every row with `status`, each offered
    /// to the card as the reducer offers open calls.
    private static func agyTranscript(open: [ChatPendingRequest], status: ChatToolActivity.Status) -> ChatTranscript {
        let entries = open.enumerated().map { index, request in
            ChatEntry(
                id: request.entryID, sourceOffset: UInt64(index),
                content: .tool(
                    ChatToolActivity(
                        kind: request.kind, name: request.toolName, title: request.summary, status: status,
                        callID: request.callID)))
        }
        return ChatTranscript(entries: entries, pendingRequests: open)
    }

    private static func question(_ id: String) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: .question, toolName: "AskUserQuestion", summary: "Colors")
    }

    private static func bash(_ id: String, _ command: String) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: .command, toolName: "Bash", summary: command)
    }

    /// A conversation whose newest turn failed, as OpenCode's `idle` row
    /// records a provider error.
    private static func failedTurn(_ message: String) -> ChatTranscript {
        let prompt = ChatEntryID("oc:msg_prompt")
        return ChatTranscript(
            entries: [
                ChatEntry(
                    id: prompt, sourceOffset: 1,
                    content: .user(ChatUserMessage(text: "Reply with exactly the word pong."))),
                ChatEntry(
                    id: ChatEntryID("oc:msg_idle"), sourceOffset: 2,
                    content: .notice(ChatNotice(kind: .error, title: message))),
            ],
            turns: [ChatTurn(firstEntryID: prompt, ending: .failed)])
    }

    /// Calls waiting for approval, running past it, and resolved.
    private static func transcript(
        pending: [ChatPendingRequest] = [], running: [ChatPendingRequest] = [], resolved: [ChatPendingRequest] = []
    ) -> ChatTranscript {
        let entries = (pending.map { ($0, ChatToolActivity.Status.awaitingApproval) }
            + running.map { ($0, ChatToolActivity.Status.running) }
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
    private var queuedReactions: [[String]: [ANSIScreen]] = [:]
    private(set) var keys: [[String]] = []
    private(set) var pastes: [String] = []
    private(set) var reads = 0
    private var failsReads = false

    init(_ screen: ANSIScreen) {
        self.screen = screen
    }

    func read() throws -> ANSIScreen {
        reads += 1
        if failsReads { throw TransportError.channelFailed(detail: "timed out") }
        return screen
    }

    /// Every read throws, as a timed-out `agent.read` does, until called
    /// with false.
    func failReads(_ fails: Bool) {
        failsReads = fails
    }

    func show(_ screen: ANSIScreen) {
        self.screen = screen
    }

    func react(to keys: [String], with screen: ANSIScreen) {
        reactions[keys] = screen
    }

    /// One screen per press of `keys`, in turn, before any fixed reaction.
    func react(to keys: [String], withEach screens: [ANSIScreen]) {
        queuedReactions[keys] = screens
    }

    func send(_ keys: [String]) {
        self.keys.append(keys)
        if var queue = queuedReactions[keys], !queue.isEmpty {
            screen = queue.removeFirst()
            queuedReactions[keys] = queue
        } else if let next = reactions[keys] {
            screen = next
        }
    }

    func paste(_ text: String) {
        pastes.append(text)
    }
}

/// The card hosted in a window, read as VoiceOver reads it: what its Esc
/// button says.
@MainActor
@Suite("Blocked card, hosted", .serialized, .timeLimit(.minutes(1)))
struct BlockedCardHostedTests {
    /// OpenCode's question footer says `esc dismiss`, and so does the
    /// card's Esc, open or folded.
    @Test func anOpenCodeQuestionsEscSaysDismiss() async throws {
        let store = try await Self.store(
            "opencode-13-question-180",
            pending: ChatPendingRequest(
                entryID: ChatEntryID("call_q"), callID: "call_q", kind: .question, toolName: "question",
                summary: "Do you prefer red or blue?"))
        try await Self.host(store) { controller in
            #expect(await Self.eventually { Self.labels(in: controller).contains("Dismiss") })
            #expect(!Self.labels(in: controller).contains("Stop"))
            store.isCollapsed = true
            #expect(await Self.eventually { Self.labels(in: controller).isSuperset(of: ["Dismiss", "Show"]) })
        }
    }

    /// An answer that showed no effect leaves the options waiting, Reject
    /// too, and Esc as the way out. It says Stop, so the open card shows no
    /// second Reject.
    @Test func anUnconfirmedOpenCodePermissionOffersStopBesideItsReject() async throws {
        let store = try await Self.store(
            "opencode-10-permission-180",
            pending: ChatPendingRequest(
                entryID: ChatEntryID("call_r"), callID: "call_r", kind: .fileRead, toolName: "read",
                summary: "/Users/developer/work/heeler-tmp-chat/opencode-a/project/.env"))
        await store.perform(.choose(ordinal: 1))
        try #require(store.progress == .unconfirmed)
        try await Self.host(store) { controller in
            #expect(await Self.eventually { Self.labels(in: controller).isSuperset(of: ["Reject", "Stop"]) })
        }
    }

    /// An OpenCode card for the dialog on `stem`, matched to `pending`.
    private static func store(_ stem: String, pending: ChatPendingRequest) async throws -> BlockedCardStore {
        let pane = FakePane(try ScreenFixture.screen(stem))
        let store = BlockedCardStore(
            program: .opencode,
            io: BlockedScreenIO(
                readScreen: { try await pane.read() },
                sendKeys: { await pane.send($0) },
                paste: { await pane.paste($0) }),
            clock: ManualClock().clock)
        store.update(transcript: ChatTranscript(entries: [], pendingRequests: [pending]))
        store.update(activity: .blocked)
        await store.refresh()
        return store
    }

    private static func host(
        _ store: BlockedCardStore, _ body: @MainActor (UIViewController) async throws -> Void
    ) async throws {
        let controller = UIHostingController(rootView: BlockedCardView(store: store, maxHeight: 600, openTerminal: {}))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try await body(controller)
        }
    }

    private static func labels(in controller: UIViewController) -> Set<String> {
        controller.view.layoutIfNeeded()
        return AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view)
    }

    private static func eventually(_ condition: () -> Bool) async -> Bool {
        var budget = PollBudget(.seconds(5))
        while budget.hasTimeLeft {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        return condition()
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
        // The call names the bare host; the dialog shows `https://example.com/`.
        let bare = request("b", "WebFetch", "https://example.com", kind: .web)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [bare])?.callID == "b")
        let other = request("o", "WebFetch", "https://example.org", kind: .web)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [other]) == nil)
        // Hosts that only start with the shown host are other hosts.
        for url in ["https://example.com.au", "https://example.community/x", "https://example.com:8080"] {
            let longer = request("l", "WebFetch", url, kind: .web)
            #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [longer]) == nil)
        }
        // A path on the same host still matches, as before.
        let path = request("p", "WebFetch", "https://example.com/docs?q=1", kind: .web)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [path])?.callID == "p")
    }

    @Test func aReadMatchesItsFile() throws {
        let path = "/var/folders/zz/probe0placeholder00000000000gn/T/heeler.hnDAu48H/"
            + "stage-474a20ea-59f3-48eb-8639-56c1977b6d41/image.jpg"
        let read = request("r", "Read", path, kind: .fileRead)
        let shown = try dialog("claude-43-c12-read-file")
        let edit = request("e", "Edit", path, kind: .fileEdit)
        #expect(BlockedRequestMatch.request(for: shown, in: [edit, read])?.callID == "r")
        // Staged images all share a name: an older Read of another one is not it.
        let other = request(
            "o", "Read",
            "/var/folders/zz/probe0placeholder00000000000gn/T/heeler.hnDAu48H/"
                + "stage-0b1c2d3e-0000-4000-8000-000000000000/image.jpg",
            kind: .fileRead)
        #expect(BlockedRequestMatch.request(for: shown, in: [other, read])?.callID == "r")
        #expect(BlockedRequestMatch.request(for: shown, in: [other]) == nil)
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

    @Test func aPlanCardShowsTheCallsPlanOnlyWhenTheScreenAgrees() throws {
        // Claude Code 2.1.301, phone width: Write to the plan file and
        // ExitPlanMode in one message; the call holds the previous plan.
        let dialog = try dialog("claude-38-c8-phone-plan-stale-call")
        #expect(dialog.kind == .claudePlan)
        let shown = dialog.body.filter { !$0.hasPrefix("Claude has written up a plan") }
        let plan = { (name: String) in
            "# Plan: create \(name)\n\n## Context\nThe user wants a file `\(name)` in "
                + "`/private/tmp/heeler-iso-4h/proj-claude-b` containing the single word `probe`.\n\n## Steps\n"
                + "1. Use the Write tool to create `/private/tmp/heeler-iso-4h/proj-claude-b/\(name)` with the "
                + "content `probe`.\n2. Verify with the Read tool that the file contains exactly `probe`.\n\n"
                + "## Verification\nRead `\(name)` and confirm it holds only the word `probe`.\n"
        }
        #expect(BlockedRequestMatch.claudePlanText(call: plan("q.txt"), shownRows: shown) == plan("q.txt"))
        let stale = BlockedRequestMatch.claudePlanText(call: plan("p2.txt"), shownRows: shown)
        #expect(stale == shown.joined(separator: "\n"))
        #expect(stale.contains("Plan: create q.txt"))
        #expect(BlockedRequestMatch.claudePlanText(call: nil, shownRows: shown) == stale)
    }

    @Test func aPlanWithAWrappedTableAndARenumberedListStillAgrees() {
        let call = "# Plan\n\n| Step | Command |\n| --- | --- |\n| Create the file named | touch a.txt && echo done |\n\n"
            + "1. First thing to do here\n1. Second thing to do here\n"
        // Drawn the way the terminal draws them: cells wrapped side by
        // side, the list renumbered.
        let shown = [
            "Plan", "┌────────────┬──────────────┐", "│ Step       │ Command      │",
            "├────────────┼──────────────┤", "│ Create the │ touch a.txt  │", "│ file named │ && echo done │",
            "└────────────┴──────────────┘", "1. First thing to do here", "2. Second thing to do here",
        ]
        #expect(BlockedRequestMatch.claudePlanText(call: call, shownRows: shown) == call)
        let other = call.replacingOccurrences(of: "touch a.txt", with: "touch b.txt")
        #expect(BlockedRequestMatch.claudePlanText(call: other, shownRows: shown) == shown.joined(separator: "\n"))
    }

    @Test func anOMPApprovalMatchesItsToolAndCommand() throws {
        let approval = try dialog("omp-24-approval-a-dialog")
        let requests = [
            request("a", "bash", "echo approved-1"), request("b", "read", "echo approved-2", kind: .fileRead),
            request("c|fc", "bash", "echo approved-2 && echo more"),
        ]
        #expect(BlockedRequestMatch.request(for: approval, in: requests)?.callID == "c|fc")
        #expect(BlockedRequestMatch.request(for: approval, in: [request("d", "Bash", "echo approved-2")]) == nil)
    }

    /// A command by its start, a file by its name, a question by its text.
    /// The subagent panel and the fork question have no call, and a
    /// subagent's approval names neither a command nor a file, so they
    /// match none of these.
    @Test(arguments: [
        "grok-12-permission-command", "grok-13-permission-compound", "grok-14-permission-edit", "grok-15-question",
        "grok-16-subagent-panel", "grok-35-permission-subagent-62", "grok-36-permission-command-40",
        "grok-37-permission-command-62", "grok-38-fork-question-62",
    ])
    func grokCardsMatchTheirCall(stem: String) throws {
        let question = "How should we handle the README rename plan?"
        let requests = [
            request("compound", "run_terminal_command", #"chmod 600 README.md; echo "EXIT_CODE:$?"; ls -l README.md"#),
            request("command", "run_terminal_command", "chmod 644 README.md"),
            request("write", "write", "/Users/developer/scratch/cap-grok-a/proj/notes.txt", kind: .fileWrite),
            request(
                "ask", "ask_user_question", question, kind: .question, questions: [ChatQuestion(text: question)]),
            // The same command under another tool's name never matches.
            request("read", "read_file", "chmod 644 README.md", kind: .fileRead),
        ]
        let expected = [
            "grok-12-permission-command": "command", "grok-13-permission-compound": "compound",
            "grok-14-permission-edit": "write", "grok-15-question": "ask", "grok-36-permission-command-40": "command",
            "grok-37-permission-command-62": "command",
        ]

        #expect(BlockedRequestMatch.request(for: try dialog(stem), in: requests)?.callID == expected[stem])
        #expect(BlockedRequestMatch.request(for: try dialog(stem), in: [requests[4]]) == nil)
    }

    /// OpenCode's action names the call's kind, and its target is the
    /// call's file; a question matches the call asking it.
    @Test func openCodeDialogsMatchTheirCallsByKindAndTarget() throws {
        let permission = try dialog("opencode-10-permission-180")
        let requests = [
            request("a", "bash", "cat .env"), request("b", "read", "/w/project/.env.example", kind: .fileRead),
            request("c", "read", "/w/project/.env", kind: .fileRead),
        ]
        #expect(BlockedRequestMatch.request(for: permission, in: requests)?.callID == "c")
        let write = request("d", "write", "/w/project/.env", kind: .fileWrite)
        #expect(BlockedRequestMatch.request(for: permission, in: [write]) == nil)

        let wrapped = try dialog("opencode-37-permission-long-62")
        let path = "config/scratch-environments/placeholder-staging-environment/phone-width-capture/dummy-settings.env"
        let read = request("e", "read", "/w/project/" + path, kind: .fileRead)
        #expect(BlockedRequestMatch.request(for: wrapped, in: [read])?.callID == "e")

        let question = try dialog("opencode-13-question-180")
        let asked = request("q", "question", "Do you prefer red or blue?", kind: .question)
        #expect(BlockedRequestMatch.request(for: question, in: [request("x", "bash", "ls"), asked])?.callID == "q")
        let other = request("y", "question", "Which size?", kind: .question)
        #expect(BlockedRequestMatch.request(for: question, in: [other]) == nil)
    }

    @Test func aCodexCommandMatchesInsideItsScript() throws {
        let script = request("x", "exec", "await tools.exec_command({cmd: \"touch x1.txt\"})")
        #expect(BlockedRequestMatch.request(for: try dialog("codex-01-x1-exec"), in: [script])?.callID == "x")
        #expect(BlockedRequestMatch.request(for: try dialog("codex-01-x1-exec"), in: [request("y", "exec", "ls")]) == nil)
    }

    /// A whole command or path matches only the call with that command or
    /// path; one the screen cut matches the call it starts.
    @Test func agyCommandsAndFilesMatchWholeOrByTheirCutStart() throws {
        let command = try dialog("agy-30-perm-run-command-default-120x40")
        let narrow = try dialog("agy-31-perm-run-command-default-40x30")
        let longer = request("l", "run_command", "sleep 40; echo probe-done; rm -rf build")
        let run = request("r", "run_command", "sleep 40; echo probe-done")
        for shown in [command, narrow] {
            #expect(!shown.subject.isRequestCut)
            #expect(BlockedRequestMatch.request(for: shown, in: [request("o", "run_command", "ls"), longer, run])?.callID == "r")
            #expect(BlockedRequestMatch.request(for: shown, in: [longer]) == nil)
        }
        #expect(BlockedRequestMatch.request(for: command, in: [request("v", "view_file", "sleep 40; echo probe-done")]) == nil)
        let cut = try agyDialog(
            "agy-30-perm-run-command-default-120x40", replacing: "   sleep 40; echo probe-done", with: "   sleep 40; echo pro…")
        #expect(cut.subject.isRequestCut)
        #expect(cut.subject.command == "sleep 40; echo pro")
        #expect(BlockedRequestMatch.request(for: cut, in: [request("o", "run_command", "ls"), run])?.callID == "r")

        let path = "/Users/developer/projects/fruits/fruits.txt"
        let edit = try dialog("agy-47-perm-file-edit-default-120x40")
        #expect(!edit.subject.isRequestCut && !edit.subject.changesAreCut)
        // A write over a file asks as an edit.
        for tool in ["replace_file_content", "edit_file", "write_to_file"] {
            #expect(BlockedRequestMatch.request(for: edit, in: [request("e", tool, path, kind: .fileEdit)])?.callID == "e")
        }
        let other = request("x", "replace_file_content", "/Users/developer/projects/fruits/calc.py", kind: .fileEdit)
        #expect(BlockedRequestMatch.request(for: edit, in: [other]) == nil)
        let backup = request("b", "edit_file", path + ".bak", kind: .fileEdit)
        #expect(BlockedRequestMatch.request(for: edit, in: [backup]) == nil)

        // At 40 columns agy cuts the path at the screen's edge.
        let created = "/Users/developer/projects/fruits2/a3note.txt"
        let create = try dialog("agy-99-perm-file-create-default-40x30")
        #expect(create.subject.isRequestCut && !create.subject.changesAreCut)
        #expect(BlockedRequestMatch.request(for: create, in: [request("w", "write_to_file", created, kind: .fileWrite)])?.callID == "w")
        #expect(BlockedRequestMatch.request(for: create, in: [request("e", "replace_file_content", created, kind: .fileEdit)]) == nil)
        #expect(!(try dialog("agy-99-perm-file-create-default-120x40")).subject.isRequestCut)
    }

    /// The card shows the screen's command, path and changed lines, and
    /// takes from the call only what the screen cut: another call's
    /// command or diff never stands in for what the screen shows whole.
    @Test func anAgyCardShowsTheScreenAndFillsInOnlyWhatItCut() throws {
        let command = try dialog("agy-30-perm-run-command-default-120x40")
        let other = request("t", "run_command", "sleep 40; echo probe-done; rm -rf build/tmp")
        #expect(BlockedRequestMatch.agyRequest(on: command, call: other) == "sleep 40; echo probe-done")
        let cut = try agyDialog(
            "agy-30-perm-run-command-default-120x40", replacing: "   sleep 40; echo probe-done", with: "   sleep 40; echo pro…")
        #expect(BlockedRequestMatch.agyRequest(on: cut, call: other) == "sleep 40; echo probe-done; rm -rf build/tmp")
        #expect(BlockedRequestMatch.agyRequest(on: cut, call: nil) == "sleep 40; echo pro…")

        let created = "/Users/developer/projects/fruits2/a3note.txt"
        let write = request("w", "write_to_file", created, kind: .fileWrite)
        #expect(BlockedRequestMatch.agyRequest(on: try dialog("agy-99-perm-file-create-default-40x30"), call: write) == created)

        // agy's dialog for approvals.jsonl step 24, with that call: the
        // screen's rows, not the call's line diff.
        let edit = try dialog("agy-47-perm-file-edit-default-120x40")
        let call = try Self.agyEditCall()
        #expect(BlockedRequestMatch.agyChanges(on: edit, call: call) == ["1  -  cherry", "1  +  cherry", "2  +  date"])
        #expect(BlockedRequestMatch.agyRequest(on: edit, call: call) == "/Users/developer/projects/fruits/fruits.txt")

        // A changed line cut at the edge: the call's change stands in.
        let long = try agyDialog(
            "agy-47-perm-file-edit-default-120x40", replacing: "date" + String(repeating: " ", count: 108),
            with: "date " + String(repeating: "x", count: 107))
        #expect(long.subject.changesAreCut)
        #expect(BlockedRequestMatch.agyChanges(on: long, call: call) == ["1     cherry", "2  +  date"])
        #expect(BlockedRequestMatch.agyChanges(on: long, call: nil) == Array(long.body.dropFirst()))
    }

    /// A permission read again at another width, its path or a changed
    /// line cut at the new edge, can be the same dialog; the next call's,
    /// which differs in a row both reads show, can't.
    @Test func agyReadsOfOneDialogAgreeWhereTheScreenCutThem() throws {
        let edit = try dialog("agy-47-perm-file-edit-default-120x40")
        for stem in [
            "agy-48-perm-file-edit-default-40x30", "agy-48-perm-file-edit-default-62x20",
            "agy-48-perm-file-edit-default-62x41",
        ] {
            #expect(BlockedRequestMatch.agyMayShowOneDialog(edit, try dialog(stem)))
        }
        let line = "date and a line long enough to be cut at forty columns"
        let wide = try agyDialog(
            "agy-47-perm-file-edit-default-120x40", replacing: "date" + String(repeating: " ", count: 108),
            with: line.padding(toLength: 112, withPad: " ", startingAt: 0))
        let narrow = try agyDialog(
            "agy-48-perm-file-edit-default-40x30", replacing: "date" + String(repeating: " ", count: 28),
            with: String(line.prefix(32)))
        #expect(!wide.subject.changesAreCut && narrow.subject.changesAreCut)
        #expect(wide.fingerprint != narrow.fingerprint)
        #expect(BlockedRequestMatch.agyMayShowOneDialog(wide, narrow))
        #expect(BlockedRequestMatch.agyMayShowOneDialog(narrow, wide))
        #expect(BlockedRequestMatch.agyRead(wide, showsAsMuchAs: narrow))
        #expect(!BlockedRequestMatch.agyRead(narrow, showsAsMuchAs: wide))
        // The next edit of the file adds another line, and a whole line
        // that only starts the same is another.
        let fig = try agyDialog(
            "agy-48-perm-file-edit-default-40x30", replacing: "date" + String(repeating: " ", count: 28),
            with: String("fig and a line long enough to be cut at forty columns".prefix(32)))
        #expect(!BlockedRequestMatch.agyMayShowOneDialog(wide, fig))
        #expect(!BlockedRequestMatch.agyMayShowOneDialog(edit, wide))
        #expect(!BlockedRequestMatch.agyMayShowOneDialog(edit, try dialog("agy-99-perm-file-create-default-120x40")))

        let command = try dialog("agy-30-perm-run-command-default-120x40")
        #expect(BlockedRequestMatch.agyMayShowOneDialog(command, try dialog("agy-31-perm-run-command-default-40x30")))
        let cut = try agyDialog(
            "agy-30-perm-run-command-default-120x40", replacing: "   sleep 40; echo probe-done", with: "   sleep 40; echo pro…")
        #expect(BlockedRequestMatch.agyMayShowOneDialog(command, cut))
        let other = try agyDialog(
            "agy-30-perm-run-command-default-120x40", replacing: "   sleep 40; echo probe-done",
            with: "   sleep 40; echo probe-fail")
        #expect(!BlockedRequestMatch.agyMayShowOneDialog(command, other))
    }

    /// Only a row a read cut agrees by its start: a changed line both
    /// reads show whole tells the next call's dialog apart, even while
    /// another line of each is cut at the edge (agy-141, 92 columns).
    @Test func agyRowsAgreeByTheirStartOnlyWhereTheScreenCutThem() throws {
        let long = "  2  +  " + String(repeating: "x", count: 84)
        func edit(setting first: String) throws -> BlockedDialog {
            try agyDialog(
                "agy-141-nocolor-perm-file-edit-92x47",
                replacing: [("  1     one", "  1  +  \(first)"), ("  2  +  two", long)])
        }
        let one = try edit(setting: "timeout = 1")
        let ten = try edit(setting: "timeout = 10")

        #expect(one.subject.cutChanges == [1])
        #expect(ten.subject.cutChanges == [1])
        #expect(!BlockedRequestMatch.agyMayShowOneDialog(one, ten))
        #expect(!BlockedRequestMatch.agyMayShowOneDialog(ten, one))
    }

    /// The call's change in the dialog's row format, from the real
    /// pending call: a line diff of its target and replacement, which keeps
    /// `cherry` as context where agy draws it removed and added again.
    @Test func agyChangeRowsAreTheCallsLineDiff() throws {
        let call = try Self.agyEditCall()
        let changes = try #require(call.fileChanges)
        #expect(BlockedRequestMatch.agyChangeRows(changes) == ["1     cherry", "2  +  date"])
        let shown = try dialog("agy-47-perm-file-edit-default-120x40")
        #expect(BlockedRequestMatch.agyChangeRows(changes) != Array(shown.body.dropFirst()))

        let write = ChatFileChanges(files: [
            .allAdded(path: "/Users/developer/projects/fruits2/a3note.txt", content: "hello a3\n", kind: .written)
        ])
        let create = try dialog("agy-99-perm-file-create-default-120x40")
        #expect(BlockedRequestMatch.agyChangeRows(write) == Array(create.body.dropFirst()))

        let context = ChatFileChanges(files: [
            ChatFileChange(
                path: "a.txt", kind: .updated,
                recorded: [ChatDiffHunk(oldStart: 4, oldLines: 2, newStart: 4, newLines: 2, lines: [" keep", "-old", "+new"])])
        ])
        #expect(BlockedRequestMatch.agyChangeRows(context) == ["4     keep", "5  -  old", "5  +  new"])
    }

    /// approvals.jsonl's edit_file call at step 24 while it waits on its
    /// dialog (agy-47): `cherry` becomes `cherry` and `date`.
    fileprivate static func agyEditCall() throws -> ChatPendingRequest {
        let transcript = try AgyTranscriptReducerTests.fixture("approvals.jsonl", steps: 21...24)
        return try #require(transcript.pendingRequests.first { $0.callID == "agy:24:tool:0" })
    }

    /// A capture with `old` replaced by `new`, which must occur in it.
    private func agyDialog(_ stem: String, replacing old: String, with new: String) throws -> BlockedDialog {
        try agyDialog(stem, replacing: [(old, new)])
    }

    /// A capture with each pair's old text, which must occur in it,
    /// replaced by its new text.
    private func agyDialog(_ stem: String, replacing pairs: [(String, String)]) throws -> BlockedDialog {
        var text = try ScreenFixture.text(stem)
        for (old, new) in pairs {
            try #require(text.contains(old))
            text = text.replacingOccurrences(of: old, with: new)
        }
        let result = AgyDialogParser.parse(ANSIScreenDecoder.decode(text))
        return try #require(result.dialog, "\(stem) edited parsed as \(result)")
    }

    @Test func agyQuestionsMatchByTheirTextAndTrustByNothing() throws {
        let question = try dialog("agy-41-ask-question-single-120x40")
        let asked = request(
            "q", "ask_question", "Which fruit do you prefer?", kind: .question,
            questions: [ChatQuestion(text: "Which fruit do you prefer?", options: ["Apple", "Banana"])])
        let other = request("o", "ask_question", "Which pet?", kind: .question, questions: [ChatQuestion(text: "Which pet?")])
        #expect(BlockedRequestMatch.request(for: question, in: [other, asked])?.callID == "q")

        let trust = try dialog("agy-00-trust-prompt-191x49")
        #expect(BlockedRequestMatch.request(for: trust, in: [asked, request("r", "run_command", "ls")]) == nil)
    }
}
