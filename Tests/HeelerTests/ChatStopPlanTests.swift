import Foundation
import Testing

@testable import Heeler

/// Chat's Stop in each program: the keys it presses in one request, the
/// guard that may read the screen first, and the wait and hint it hands
/// the Composer.
@MainActor
@Suite("Chat Stop plan")
struct ChatStopPlanTests {
    @Test(arguments: [ChatProgram.claude, .codex, .pi, .omp, .agy])
    func oneEscAndThreeSecondsForEveryProgramButGrokAndOpenCode(program: ChatProgram) {
        let plan = ChatStopPlan.standard(for: program)

        #expect(plan.keys == ["esc"])
        // Only Antigravity CLI's Esc reads the screen first (below).
        #expect((plan.screenGuard == nil) == (program != .agy))
        #expect(plan.wait == AgentStopWait.escape)
        #expect(plan.wait.window == .seconds(3))
        #expect(plan.wait.unconfirmedNotice == "Esc went, but the Agent still shows Working.")
        #expect(plan.wait.minimumGap == .zero)
        #expect(plan.accessibilityHint == "Presses Esc to interrupt the Agent")
    }

    @Test(arguments: ChatProgram.allCases)
    func everyPlanSendsKeysHerdrAccepts(program: ChatProgram) {
        let keys = ChatStopPlan.standard(for: program).keys

        #expect(!keys.isEmpty)
        for key in keys {
            #expect(HerdrKeyGrammar.accepts(key), "\(program) presses \(key)")
        }
    }

    /// Grok Build's guard reads the screen inside the keys queue; then one
    /// Ctrl+C goes, or nothing does and Stop says why.
    @Test func grokPressesOneCtrlCAfterItsGuard() async throws {
        let recorder = StopRecorder()
        let agentKeys = Self.agentKeys(recorder)
        let plan = ChatStopPlan.standard(for: .grok)
        let working = plan.composerInterrupt(
            context: Self.context(recorder, screen: try ScreenFixture.screen("grok-03-working")),
            agentKeys: agentKeys)
        let drafting = plan.composerInterrupt(
            context: Self.context(recorder, screen: try ScreenFixture.screen("grok-04-working-draft")),
            agentKeys: agentKeys)

        let pressed = await working.perform()
        #expect(pressed == .sent)
        #expect(recorder.events == ["read", "ctrl+c"])

        let refused = await drafting.perform()
        let reason = "Grok Build's input box has text, and Ctrl+C would only clear it. Stop it in the terminal."
        #expect(refused == .failed(reason))
        #expect(recorder.contextCalls == 2)
        #expect(recorder.sent == [["ctrl+c"]], "a refused Stop presses nothing")
    }

    @Test func theGrokPlanWaitsThreeSecondsAndKeepsPressesApart() {
        let plan = ChatStopPlan.standard(for: .grok)

        #expect(plan.keys == ["ctrl+c"])
        #expect(plan.wait.window == .seconds(3))
        #expect(plan.wait.minimumGap == .milliseconds(1500))
        #expect(
            plan.wait.unconfirmedNotice
                == "Ctrl+C went, but the Agent still shows Working. A queued message may have started.")
        #expect(plan.accessibilityHint == "Presses Ctrl+C to cancel the turn")
    }

    /// The Template names the key, which may not be Esc, so nothing says it was.
    @Test func aTemplatesStopKeepsTheProgramsWaitAndDoesNotNameItsKey() {
        let plan = ChatStopPlan.standard(for: .claude).pressing(templateStopKey: "ctrl+c")

        #expect(plan.keys == ["ctrl+c"])
        #expect(plan.wait.window == .seconds(3))
        #expect(plan.wait.minimumGap == .zero)
        #expect(plan.wait.unconfirmedNotice == "Stop went, but the Agent still shows Working.")
        #expect(plan.accessibilityHint == AgentComposerInterrupt.coreHint)

        let grok = ChatStopPlan.standard(for: .grok).pressing(templateStopKey: "esc")
        #expect(grok.wait.minimumGap == .milliseconds(1500))
        #expect(grok.wait.unconfirmedNotice == "Stop went, but the Agent still shows Working.")
    }

    @Test func anUnguardedPlanSendsEveryKeyInOneRequestWithoutReading() async {
        let recorder = StopRecorder()
        let plan = ChatStopPlan(keys: ["esc", "esc"], wait: .escape, accessibilityHint: "Presses Esc twice")
        let interrupt = plan.composerInterrupt(context: Self.context(recorder), agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .sent)
        #expect(recorder.sent == [["esc", "esc"]])
        #expect(recorder.contextCalls == 0, "a plan without a guard never reads the screen")
    }

    @Test func aGuardSeesTheScreenAndStatusAndMayRefuse() async throws {
        let recorder = StopRecorder()
        let seen = SeenContexts()
        let plan = Self.guarded { context in
            seen.contexts.append(context)
            return .refuse("Not now.")
        }
        let screen = ScreenFixture.synthetic(["a dialog row"])
        let interrupt = plan.composerInterrupt(
            context: Self.context(recorder, screen: screen, activity: .blocked), agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .failed("Not now."))
        #expect(recorder.contextCalls == 1)
        #expect(recorder.sent.isEmpty, "a refused Stop presses nothing")
        let context = try #require(seen.contexts.first)
        #expect(seen.contexts.count == 1)
        #expect(context.activity == .blocked)
        #expect(context.screen.rows == screen.rows)
    }

    @Test func aGuardThatAllowsSendsTheKeys() async {
        let recorder = StopRecorder()
        let plan = Self.guarded(keys: ["esc", "esc"]) { _ in .press }
        let interrupt = plan.composerInterrupt(context: Self.context(recorder), agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .sent)
        #expect(recorder.contextCalls == 1)
        #expect(recorder.sent == [["esc", "esc"]])
    }

    @Test func anUnreadableScreenSendsNothing() async {
        let recorder = StopRecorder()
        let seen = SeenContexts()
        let plan = Self.guarded { context in
            seen.contexts.append(context)
            return .press
        }
        let interrupt = plan.composerInterrupt(
            context: Self.context(recorder, readFails: true), agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .failed("Heeler couldn't check the Agent's screen, so Stop pressed nothing."))
        #expect(recorder.sent.isEmpty)
        #expect(seen.contexts.isEmpty, "a guard decides only on a screen it saw")
    }

    @Test func aFailedRequestSaysTheAgentMayStillBeWorking() async {
        let recorder = StopRecorder()
        let interrupt = ChatStopPlan.escape.composerInterrupt(
            context: Self.context(recorder), agentKeys: Self.agentKeys(recorder, requestsFail: true))

        let outcome = await interrupt.perform()

        #expect(outcome == .failed("Couldn't reach the Agent, so it may still be working."))
    }

    /// Up recalls history into the input box, so a guard must see the
    /// screen once the keys pressed before Stop have gone.
    @Test func aGuardReadsOnlyAfterKeysAlreadyQueued() async {
        let gate = ScriptedTransportCallGate()
        let recorder = StopRecorder()
        let agentKeys = Self.agentKeys(recorder, firstRequestWaitsOn: gate)
        let interrupt = Self.guarded { _ in .press }
            .composerInterrupt(context: Self.context(recorder), agentKeys: agentKeys)

        agentKeys.press(.up)
        let stop = Task { await interrupt.perform() }
        await gate.waitForEntry()
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.contextCalls == 0, "the guard waits for the key pressed before Stop")

        await gate.open()
        let outcome = await stop.value
        #expect(outcome == .sent)
        #expect(recorder.events == ["up", "read", "esc"])
    }

    @Test func theComposerInterruptCarriesThePlan() async {
        let recorder = StopRecorder()
        let agentKeys = Self.agentKeys(recorder)
        let plan = ChatStopPlan(
            keys: ["esc"],
            wait: AgentStopWait(
                window: .seconds(5), unconfirmedNotice: "Keys went, but the Agent still shows Working.",
                minimumGap: .milliseconds(1500)),
            accessibilityHint: "Presses the program's Stop keys")
        let carried = plan.composerInterrupt(context: Self.context(recorder), agentKeys: agentKeys)
        #expect(carried.wait == plan.wait)
        #expect(carried.accessibilityHint == plan.accessibilityHint)

        let escape = ChatStopPlan.escape.composerInterrupt(context: Self.context(recorder), agentKeys: agentKeys)
        #expect(escape.wait == ChatStopPlan.escape.wait)
        #expect(escape.accessibilityHint == ChatStopPlan.escape.accessibilityHint)
        let outcome = await escape.perform()
        #expect(outcome == .sent)
        #expect(recorder.sent == [["esc"]])
        #expect(recorder.contextCalls == 0)
    }

    // MARK: OpenCode

    /// OpenCode's first Esc arms its interrupt and the second interrupts,
    /// so both go in one request once the guard reads a running turn.
    @Test func openCodePressesEscTwiceInOneRequest() async throws {
        let plan = ChatStopPlan.standard(for: .opencode)
        #expect(plan.keys == ["esc", "esc"])
        #expect(plan.screenGuard != nil)
        #expect(
            plan.wait
                == AgentStopWait(window: .seconds(3), unconfirmedNotice: OpenCodeStopCopy.notice, minimumGap: .zero))
        #expect(plan.accessibilityHint == "Presses Esc twice to interrupt OpenCode")

        let recorder = StopRecorder()
        let interrupt = plan.composerInterrupt(
            context: Self.context(recorder, screen: try ScreenFixture.screen("opencode-08-working-180")),
            agentKeys: Self.agentKeys(recorder))
        #expect(interrupt.wait == plan.wait)
        #expect(interrupt.accessibilityHint == plan.accessibilityHint)

        let outcome = await interrupt.perform()

        #expect(outcome == .sent)
        #expect(recorder.contextCalls == 1)
        #expect(recorder.sent == [["esc", "esc"]])
    }

    /// The footer shows a turn running, at either width, whether or not
    /// one Esc already armed the interrupt, and with a prompt queued.
    @Test(arguments: [
        "opencode-08-working-180", "opencode-09-armed-180", "opencode-35-working-62", "opencode-36-armed-62",
        "opencode-43-queued-dock-62",
    ])
    func openCodeStopPressesOnARunningTurn(stem: String) throws {
        #expect(try Self.openCodeVerdict(stem) == .press)
    }

    /// Where Esc would reject a permission, dismiss a question, close a
    /// menu or leave shell mode, or where no turn of this conversation
    /// runs, Stop presses nothing and says why.
    @Test(arguments: [
        ("opencode-10-permission-180", OpenCodeStopCopy.answer), ("opencode-13-question-180", OpenCodeStopCopy.answer),
        ("opencode-25-reject-feedback-180", OpenCodeStopCopy.answer),
        ("opencode-37-permission-long-62", OpenCodeStopCopy.answer),
        ("opencode-38-question-long-62", OpenCodeStopCopy.answer),
        ("opencode-04-slash-popup-180", OpenCodeStopCopy.menu), ("opencode-06-at-popup-180", OpenCodeStopCopy.menu),
        ("opencode-14-session-picker-180", OpenCodeStopCopy.menu),
        ("opencode-39-slash-popup-62", OpenCodeStopCopy.menu),
        ("opencode-07-shell-mode-180", OpenCodeStopCopy.shell), ("opencode-40-shell-mode-62", OpenCodeStopCopy.shell),
        ("opencode-15-subagent-panel-180", OpenCodeStopCopy.elsewhere),
        ("opencode-41-subagent-panel-62", OpenCodeStopCopy.elsewhere),
        ("opencode-01-home-empty-180", OpenCodeStopCopy.elsewhere),
        ("opencode-30-home-empty-62", OpenCodeStopCopy.elsewhere),
        ("opencode-21-done-interrupted-180", OpenCodeStopCopy.idle),
        ("opencode-32-session-empty-62", OpenCodeStopCopy.idle),
    ])
    func openCodeStopRefusesWhereEscWouldDoSomethingElse(stem: String, reason: String) throws {
        #expect(try Self.openCodeVerdict(stem) == .refuse(reason))
    }

    /// herdr's status says whether the turn runs: a running footer on
    /// screen doesn't make Stop press while herdr reports anything else.
    @Test(arguments: [ChatAgentActivity.idle, .blocked, .unknown])
    func openCodeStopRefusesWhenHerdrIsNotWorking(activity: ChatAgentActivity) async throws {
        let recorder = StopRecorder()
        let interrupt = ChatStopPlan.standard(for: .opencode).composerInterrupt(
            context: Self.context(
                recorder, screen: try ScreenFixture.screen("opencode-08-working-180"), activity: activity),
            agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .failed(OpenCodeStopCopy.ended))
        #expect(recorder.contextCalls == 1)
        #expect(recorder.sent.isEmpty)
    }

    /// Ctrl+C exits OpenCode when its input is empty, and Ctrl+D exits it
    /// too: only Esc goes.
    @Test func openCodeStopNeverSendsControlKeysThatQuit() {
        let keys = ChatStopPlan.standard(for: .opencode).keys

        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy { $0 == "esc" }, "\(keys)")
        #expect(!keys.contains { $0.lowercased().hasPrefix("ctrl") || $0.lowercased().hasPrefix("c-") })
    }

    // MARK: Antigravity CLI

    /// One Esc in bash mode leaves it and drops the command typed there
    /// (agy-93), so Stop presses nothing then and says why.
    @Test func agyStopRefusesABashCommandItWouldDrop() async throws {
        let recorder = StopRecorder()
        let interrupt = ChatStopPlan.standard(for: .agy).composerInterrupt(
            context: Self.context(recorder, screen: try ScreenFixture.screen("agy-93-bash-mode-with-text-62x41")),
            agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(
            outcome
                == .failed(
                    "Antigravity CLI's input box is in bash mode with a command typed, and Esc would drop it. Stop it in the terminal."
                ))
        #expect(recorder.contextCalls == 1)
        #expect(recorder.sent.isEmpty, "a refused Stop presses nothing")
    }

    /// Anywhere else one Esc goes: on a running turn, with a draft or a
    /// message queued, on a dialog, and in bash mode with nothing typed.
    @Test(arguments: [
        "agy-66-working-nodraft-62x41", "agy-67-working-tool-running-62x41", "agy-68-working-with-draft-62x41",
        "agy-70-working-queued-after-approve-62x41", "agy-96-working-queued-40x30",
        "agy-69-working-draft-entered-then-perm-dialog-62x41", "agy-91-bang-typed-62x41",
    ])
    func agyStopPressesOneEsc(stem: String) async throws {
        let recorder = StopRecorder()
        let interrupt = ChatStopPlan.standard(for: .agy).composerInterrupt(
            context: Self.context(recorder, screen: try ScreenFixture.screen(stem)),
            agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .sent)
        #expect(recorder.events == ["read", "esc"])
    }

    /// What Stop presses for the commands agy sent to the background is
    /// read as Stop is tapped, runs once the Esc went, and what it left
    /// running is what Stop says.
    @Test func agyStopFollowsThroughAfterItsEsc() async throws {
        let recorder = StopRecorder()
        let interrupt = ChatStopPlan.standard(for: .agy).composerInterrupt(
            context: Self.context(
                recorder, screen: try ScreenFixture.screen("agy-169-plain-working-background-task-120x40")),
            agentKeys: Self.agentKeys(recorder),
            followThrough: {
                recorder.events.append("tap")
                return {
                    recorder.events.append("panel")
                    return "sleep 40 still runs."
                }
            })

        let outcome = await interrupt.perform()

        #expect(outcome == .sentLeavingWork("sleep 40 still runs."))
        #expect(recorder.events == ["tap", "read", "esc", "panel"])
    }

    /// A follow-through that ended everything leaves a plain `.sent`, and a
    /// withheld Esc runs none.
    @Test func agyStopFollowsThroughOnlyAfterAnEscThatWent() async throws {
        let ended = StopRecorder()
        let sent = await ChatStopPlan.standard(for: .agy).composerInterrupt(
            context: Self.context(ended), agentKeys: Self.agentKeys(ended),
            followThrough: { { ended.events.append("panel"); return nil } }
        ).perform()
        #expect(sent == .sent)
        #expect(ended.events == ["read", "esc", "panel"])

        let refused = StopRecorder()
        let withheld = await ChatStopPlan.standard(for: .agy).composerInterrupt(
            context: Self.context(refused, screen: try ScreenFixture.screen("agy-93-bash-mode-with-text-62x41")),
            agentKeys: Self.agentKeys(refused),
            followThrough: { { refused.events.append("panel"); return "unexpected" } }
        ).perform()
        #expect(withheld == .failed(AgyStopGuard.bashCommand))
        #expect(refused.events == ["read"])
    }

    /// Keys pressed while a follow-through types wait for it, so a second
    /// Stop's Esc never lands between its keys.
    @Test func keysWaitForAFollowThroughInTheQueue() async {
        let recorder = StopRecorder()
        let gate = ScriptedTransportCallGate()
        let keys = Self.agentKeys(recorder)
        let followThrough = Task {
            await keys.afterQueued {
                recorder.events.append("panel")
                await gate.waitUntilOpen()
                recorder.events.append("closed")
            }
        }
        await gate.waitForEntry()
        let esc = Task { await keys.deliver(["esc"]) }
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.events == ["panel"])

        await gate.open()
        await followThrough.value
        #expect(await esc.value == .sent)
        #expect(recorder.events == ["panel", "closed", "esc"])
    }

    /// A Composer send goes outside the keys queue, so Chat holds one from
    /// the moment a follow-through is queued until it ends: typed between
    /// two of its keys, it would land in its `/tasks`.
    @Test func aFollowThroughHoldsSendsUntilItEnds() async {
        let earlier = ScriptedTransportCallGate()
        let panel = ScriptedTransportCallGate()
        let keys = Self.agentKeys(StopRecorder(), firstRequestWaitsOn: earlier)
        #expect(!keys.isRunningQueuedWork)

        let esc = Task { await keys.deliver(["esc"]) }
        await earlier.waitForEntry()
        let followThrough = Task { await keys.afterQueued { await panel.waitUntilOpen() } }
        for _ in 0..<20 { await Task.yield() }
        #expect(keys.isRunningQueuedWork, "queued behind the Esc")

        await earlier.open()
        _ = await esc.value
        await panel.waitForEntry()
        #expect(keys.isRunningQueuedWork, "typing")

        await panel.open()
        await followThrough.value
        #expect(!keys.isRunningQueuedWork)
    }

    /// agy is Idle while the follow-through types, so no status change
    /// ended the held send's notice, which stayed after it until the draft
    /// changed (live). It ends with the work; a notice for another reason,
    /// or one noted once the work ended, stays. The terminal page's Send
    /// waits the same way: the Agent's keys queue is its Composer's.
    @Test(arguments: [ComposerRoute.chat, .terminal])
    func aSendHeldForAFollowThroughSaysSoUntilItEnds(route: ComposerRoute) async {
        let composer = AgentComposerStore(target: "w1:p1", initialStatus: .idle) { _ in
            throw TransportError.cancelled
        }
        let session = AgentComposerSession(composer: composer)
        let keys = session.agentKeys
        let hold = ComposerRefusal.inputNotReady(AgyBackgroundTaskStop.sendHold)
        let other = ComposerRefusal.inputNotReady("Claude Code is switching a setting. Try again in a moment.")
        /// A Send from `route`'s surface, refused for `refusal` or else as
        /// that surface holds it.
        func send(refusedFor refusal: ComposerRefusal? = nil) async -> AgentComposerStore.SendResult {
            var policy =
                route == .chat
                ? ComposerDeliveryPolicy(
                    route: .chat, insertsIntoAttachWhenBlocked: false, outgoingText: { $0 }, validate: { _ in nil },
                    preflight: { _ in session.heldSend() }, verify: nil)
                : session.terminalSendPolicy(attach: nil)
            if let refusal { policy.preflight = { _ in refusal } }
            return await composer.send(policy: policy)
        }
        /// A follow-through, with `meanwhile` sent as it types.
        func followThrough(_ meanwhile: () async -> Void) async {
            let panel = ScriptedTransportCallGate()
            let work = Task { await keys.afterQueued { await panel.waitUntilOpen() } }
            await panel.waitForEntry()
            await meanwhile()
            await panel.open()
            await work.value
        }
        composer.replaceDraft(with: "and the tests")

        await followThrough {
            #expect(await send() == .refused(hold))
            #expect(composer.notice == ComposerNotice(refusal: hold, route: route))
        }
        #expect(composer.notice == nil)
        #expect(composer.draft == "and the tests")

        await followThrough {
            _ = await send()
            _ = await send(refusedFor: other)
        }
        #expect(composer.notice?.refusal == other)

        _ = await send(refusedFor: hold)
        await followThrough {}
        #expect(composer.notice?.refusal == hold)
    }

    /// A Retry tapped while the follow-through types is held as a Send is.
    /// The message keeps the failure it was retried for, so neither the
    /// Composer's failure row nor Chat's echo says the hold once it ended.
    @Test func aRetryHeldForAFollowThroughKeepsItsReason() async throws {
        let composer = AgentComposerStore(target: "w1:p1", initialStatus: .idle) { _ in
            throw TransportError.sshUnreachable(detail: "offline")
        }
        let session = AgentComposerSession(composer: composer)
        let policy = ComposerDeliveryPolicy(
            route: .chat, insertsIntoAttachWhenBlocked: false, outgoingText: { $0 }, validate: { _ in nil },
            preflight: { _ in session.heldSend() }, verify: nil)
        let hold = ComposerRefusal.inputNotReady(AgyBackgroundTaskStop.sendHold)
        composer.replaceDraft(with: "and the tests")
        #expect(await composer.send(policy: policy) == .failed)
        let failed = try #require(composer.messages.first)
        guard case .failed(let reason) = failed.state else {
            Issue.record("the send should have failed: \(failed.state)")
            return
        }
        let panel = ScriptedTransportCallGate()
        let work = Task { await session.agentKeys.afterQueued { await panel.waitUntilOpen() } }
        await panel.waitForEntry()

        #expect(await composer.retry(failed.id, policy: policy) == .refused(hold))
        #expect(composer.notice == ComposerNotice(refusal: hold, route: .chat))
        #expect(composer.messages.map(\.state) == [.failed(reason)])
        await panel.open()
        await work.value

        #expect(composer.notice == nil)
        #expect(composer.messages.map(\.state) == [.failed(reason)])
        #expect(ChatComposerEchoes.pending(composer.messages, statuses: [:]).map(\.state) == [.failed(reason)])
    }

    // MARK: Helpers

    /// What OpenCode's guard says on a capture while herdr reports Working.
    private static func openCodeVerdict(_ stem: String) throws -> ChatStopVerdict {
        let screenGuard = try #require(ChatStopPlan.standard(for: .opencode).screenGuard)
        return screenGuard(ChatStopContext(screen: try ScreenFixture.screen(stem), activity: .working))
    }

    /// A real keys store over `recorder`. The first request waits on
    /// `gate` when one is given; with `requestsFail`, every request throws.
    private static func agentKeys(
        _ recorder: StopRecorder, firstRequestWaitsOn gate: ScriptedTransportCallGate? = nil,
        requestsFail: Bool = false
    ) -> ChatAgentKeysStore {
        ChatAgentKeysStore { keys in
            recorder.calls += 1
            if recorder.calls == 1, let gate { await gate.waitUntilOpen() }
            if requestsFail { throw TransportError.cancelled }
            recorder.sent.append(keys)
            recorder.events.append(keys.joined(separator: " "))
        }
    }

    /// A Stop context that counts its reads: `screen` with the Agent's
    /// `activity` (by default a probe row while it works), or a failed read.
    private static func context(
        _ recorder: StopRecorder, screen: ANSIScreen = ScreenFixture.synthetic(["probe row"]),
        activity: ChatAgentActivity = .working, readFails: Bool = false
    ) -> @MainActor () async throws -> ChatStopContext {
        {
            recorder.contextCalls += 1
            recorder.events.append("read")
            if readFails { throw TransportError.timedOut }
            return ChatStopContext(screen: screen, activity: activity)
        }
    }

    /// A synthetic plan whose guard decides.
    private static func guarded(
        keys: [String] = ["esc"], _ screenGuard: @escaping @Sendable (ChatStopContext) -> ChatStopVerdict
    ) -> ChatStopPlan {
        ChatStopPlan(
            keys: keys, screenGuard: screenGuard, wait: .escape,
            accessibilityHint: AgentComposerInterrupt.escapeHint)
    }
}

/// What Chat's keys sent and how often a Stop context was read; `events`
/// keeps both in the order they happened.
@MainActor
private final class StopRecorder {
    var calls = 0
    var sent: [[String]] = []
    var contextCalls = 0
    var events: [String] = []
}

/// The contexts a guard was shown. Guards run inside the keys queue's
/// check, on the main actor.
private final class SeenContexts: @unchecked Sendable {
    var contexts: [ChatStopContext] = []
}

/// What OpenCode's Stop says after its keys showed no effect, and where it
/// presses nothing.
private enum OpenCodeStopCopy {
    static let notice =
        "Esc went twice, but OpenCode still shows Working. If a message was waiting during this turn, OpenCode runs "
        + "it after a stop; tap Stop again to stop that too. In the terminal, use Esc, not Ctrl+C, which exits "
        + "OpenCode when its input is empty."
    static let ended = "The turn already ended, so Stop pressed nothing."
    static let answer =
        "OpenCode is asking for an answer, and Esc would reject it. Answer the card, or stop in the terminal."
    static let elsewhere =
        "OpenCode isn't showing this conversation's prompt, so Stop pressed nothing. Stop it in the terminal."
    static let menu =
        "A menu is open over OpenCode's prompt, and Esc would only close it. Close it in the terminal first."
    static let shell = "OpenCode's prompt is in shell mode, where Esc only leaves it. Stop it in the terminal."
    static let idle = "OpenCode's screen shows no running turn, so Stop pressed nothing."
}
