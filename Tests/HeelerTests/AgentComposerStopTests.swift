import Foundation
import Testing

@testable import Heeler

/// Send becomes Stop only for a Working Agent and a blank draft, so a prompt
/// typed during a turn still queues behind it.
@Suite("Agent Composer primary control")
struct AgentComposerPrimaryControlTests {
    @Test func aWorkingAgentWithABlankDraftGetsStop() {
        #expect(AgentComposerPrimaryControl(status: .working, draft: "", canStop: true) == .stop)
        #expect(AgentComposerPrimaryControl(status: .working, draft: " \n\t", canStop: true) == .stop)
    }

    @Test func textKeepsSendSoAPromptCanQueue() {
        #expect(
            AgentComposerPrimaryControl(status: .working, draft: "and the tests", canStop: true)
                == .send)
        #expect(
            AgentComposerPrimaryControl(
                status: .working, draft: "", hasAttachments: true, canStop: true)
                == .send)
        #expect(
            AgentComposerPrimaryControl(
                status: .blocked, draft: "", hasAttachments: true, canStop: true,
                alsoWhileBlocked: true)
                == .send)
    }

    @Test func onlyWorkingOffersStop() {
        // Esc on a Blocked dialog answers it; on Claude's folder trust
        // dialog it exits Claude Code.
        for status in [AgentStatus.idle, .done, .blocked, .unknown] {
            #expect(
                AgentComposerPrimaryControl(status: status, draft: "", canStop: true) == .send,
                "status \(status.rawValue)")
        }
    }

    @Test func aSurfaceWithoutAnInterruptKeepsSend() {
        #expect(AgentComposerPrimaryControl(status: .working, draft: "", canStop: false) == .send)
    }

    @Test func blockedOffersStopOnlyWhenTheHostKeepsItThere() {
        #expect(
            AgentComposerPrimaryControl(status: .blocked, draft: "", canStop: true, alsoWhileBlocked: true)
                == .stop)
        #expect(
            AgentComposerPrimaryControl(
                status: .blocked, draft: "and the tests", canStop: true, alsoWhileBlocked: true)
                == .send)
        for status in [AgentStatus.idle, .done, .unknown] {
            #expect(
                AgentComposerPrimaryControl(
                    status: status, draft: "", canStop: true, alsoWhileBlocked: true)
                    == .send,
                "status \(status.rawValue)")
        }
    }
}

@Suite("Agent Composer collapse")
struct AgentComposerCollapseTests {
    @Test func theFoldWaitsForTheKeyboardToStartDown() {
        let collapsed = { (keyboardIsLeaving: Bool) in
            AgentComposerCollapse.isCollapsed(
                isEnabled: true, isInputFocused: false, keyboardPresentation: .hidden,
                inheritsKeyboard: false, hasInputReplacement: false,
                keyboardIsLeaving: keyboardIsLeaving)
        }
        #expect(!collapsed(true))
        #expect(collapsed(false))
    }

    @Test func foldsOnlyWhileNothingHoldsOrAwaitsTheKeyboard() {
        #expect(Self.folds())
        #expect(!Self.folds(isEnabled: false), "the terminal keeps its height")
        #expect(!Self.folds(isInputFocused: true))
        #expect(!Self.folds(keyboardPresentation: .system), "asked for before focus lands")
        #expect(
            !Self.folds(keyboardPresentation: .tools),
            "the iPad tools dock releases focus, but swapping keyboards never resizes the Composer")
        #expect(!Self.folds(inheritsKeyboard: true), "a handed-over keyboard opens it from the first frame")
        #expect(!Self.folds(hasInputReplacement: true), "the Blocked card keeps its own layout")
    }

    private static func folds(
        isEnabled: Bool = true,
        isInputFocused: Bool = false,
        keyboardPresentation: AgentComposerKeyboardPresentation = .hidden,
        inheritsKeyboard: Bool = false,
        hasInputReplacement: Bool = false
    ) -> Bool {
        AgentComposerCollapse.isCollapsed(
            isEnabled: isEnabled,
            isInputFocused: isInputFocused,
            keyboardPresentation: keyboardPresentation,
            inheritsKeyboard: inheritsKeyboard,
            hasInputReplacement: hasInputReplacement)
    }
}

@Suite("Agent Composer keyboard pull")
struct AgentComposerKeyboardPullTests {
    private typealias Pull = AgentComposerKeyboardPull

    @Test func theGrabberMovesDownOnlyAndLessThanTheFinger() {
        #expect(Pull.grabberOffset(translation: -30) == 0)
        #expect(Pull.grabberOffset(translation: 0) == 0)
        for translation: CGFloat in [4, 20, 44, 400] {
            #expect(Pull.grabberOffset(translation: translation) < translation)
        }
    }

    @Test func eachPointOfThePullMovesTheGrabberLess() {
        let early = Pull.grabberOffset(translation: 10) - Pull.grabberOffset(translation: 0)
        let late = Pull.grabberOffset(translation: 40) - Pull.grabberOffset(translation: 30)
        #expect(late < early)
        #expect(Pull.grabberOffset(translation: 10_000) < 18)
    }

    @Test func theKeyboardGoesAtTheDistanceWithoutARelease() {
        #expect(!Pull.reachesHidingDistance(translation: 43))
        #expect(Pull.reachesHidingDistance(translation: 44))
    }

    @Test func aShortFlickDownHidesTheKeyboard() {
        #expect(Pull.isFlickDown(translation: 12, predictedTranslation: 200))
        #expect(!Pull.isFlickDown(translation: 12, predictedTranslation: 60))
        #expect(!Pull.isFlickDown(translation: -10, predictedTranslation: 200))
    }
}

/// One Esc per tap, then a wait on Agent Status: an Esc landing after the
/// turn ended can open the program's own history menus.
@MainActor
@Suite("Agent Composer Stop")
struct AgentComposerStopStoreTests {
    @Test func aSecondTapWaitsForTheStatusInsteadOfPressingAgain() async {
        let window = ScriptedTransportCallGate()
        let store = AgentComposerStopStore(sleep: { _ in await window.waitUntilOpen() })
        let esc = EscRecorder()

        let wait = store.stop(using: { await esc.press() })
        #expect(store.stop(using: { await esc.press() }) == nil)
        await window.waitForEntry()
        #expect(esc.count == 1)
        #expect(store.isStopping)
        #expect(store.stop(using: { await esc.press() }) == nil)

        store.agentStatusChanged(to: .idle)
        #expect(store.phase == .ready)
        await window.open()
        await wait?.value
        #expect(store.phase == .ready, "a wait the status overtook must not come back")
        #expect(esc.count == 1)
    }

    @Test func blockedEndsTheWaitUnlessStopStaysOffered() async {
        let ending = ScriptedTransportCallGate()
        let endingStore = AgentComposerStopStore(sleep: { _ in await ending.waitUntilOpen() })
        let endingWait = endingStore.stop(using: { .sent })
        await ending.waitForEntry()
        endingStore.agentStatusChanged(to: .blocked)
        #expect(endingStore.phase == .ready)
        await ending.open()
        await endingWait?.value

        let keeping = ScriptedTransportCallGate()
        let keepingStore = AgentComposerStopStore(sleep: { _ in await keeping.waitUntilOpen() })
        let keepingWait = keepingStore.stop(using: { .sent })
        await keeping.waitForEntry()
        keepingStore.agentStatusChanged(to: .blocked, keepWaitingWhileBlocked: true)
        #expect(keepingStore.isStopping)
        keepingStore.agentStatusChanged(to: .idle, keepWaitingWhileBlocked: true)
        #expect(keepingStore.phase == .ready)
        await keeping.open()
        await keepingWait?.value
        #expect(keepingStore.phase == .ready)
    }

    @Test func workingUpdatesKeepWaiting() async {
        let window = ScriptedTransportCallGate()
        let store = AgentComposerStopStore(sleep: { _ in await window.waitUntilOpen() })

        let wait = store.stop(using: { .sent })
        await window.waitForEntry()
        store.agentStatusChanged(to: .working)
        #expect(store.isStopping)

        await window.open()
        await wait?.value
        #expect(store.phase == .unconfirmed)
    }

    @Test func pastTheWindowStopWorksAgainAndSaysWhatItSees() async {
        let store = AgentComposerStopStore(sleep: { _ in })
        let esc = EscRecorder()

        await store.stop(using: { await esc.press() })?.value
        #expect(store.phase == .unconfirmed)
        #expect(store.notice == "Esc went, but the Agent still shows Working.")
        #expect(!store.isStopping)

        await store.stop(using: { await esc.press() })?.value
        #expect(esc.count == 2)
    }

    @Test func aFailedEscSaysWhyAndSkipsTheWindow() async {
        let window = ScriptedTransportCallGate()
        await window.open()
        let store = AgentComposerStopStore(sleep: { _ in await window.waitUntilOpen() })
        let esc = EscRecorder()
        esc.outcome = .failed("Couldn't reach the Agent, so it may still be working.")

        await store.stop(using: { await esc.press() })?.value
        #expect(store.phase == .failed("Couldn't reach the Agent, so it may still be working."))
        #expect(store.notice == "Couldn't reach the Agent, so it may still be working.")
        #expect(await window.entryCount == 0)

        esc.outcome = .sent
        await store.stop(using: { await esc.press() })?.value
        #expect(esc.count == 2)
        #expect(store.phase == .unconfirmed)
    }

    @Test func aSendHoldsStopBackUntilItsOwnMomentPasses() async {
        let first = ScriptedTransportCallGate()
        let second = ScriptedTransportCallGate()
        let gates = GateQueue([first, second])
        let store = AgentComposerStopStore(sleep: { _ in await gates.next().waitUntilOpen() })

        let firstHold = store.holdAfterSend()
        #expect(store.isHeldAfterSend)
        await first.waitForEntry()
        let secondHold = store.holdAfterSend()
        await second.waitForEntry()

        await first.open()
        await firstHold.value
        #expect(store.isHeldAfterSend, "the later send's moment is still running")
        await second.open()
        await secondHold.value
        #expect(!store.isHeldAfterSend)
    }

    @Test func aStatusChangeWhileEscIsOnItsWayWins() async {
        let send = ScriptedTransportCallGate()
        let store = AgentComposerStopStore(sleep: { _ in })

        let wait = store.stop(using: {
            await send.waitUntilOpen()
            return .failed("late")
        })
        await send.waitForEntry()
        store.agentStatusChanged(to: .done)
        await send.open()
        await wait?.value
        #expect(store.phase == .ready)
        #expect(store.notice == nil)
    }

    /// What a Stop left running is said after the turn it ended left
    /// Working, which ends every other notice, until the Agent works again.
    @Test func whatStopLeftRunningOutlastsTheTurnItEnded() async {
        let send = ScriptedTransportCallGate()
        let store = AgentComposerStopStore(sleep: { _ in })

        let wait = store.stop(using: {
            await send.waitUntilOpen()
            return .sentLeavingWork("sleep 40 still runs.")
        })
        await send.waitForEntry()
        store.agentStatusChanged(to: .idle)
        await send.open()
        await wait?.value
        #expect(store.phase == .ready)
        #expect(store.notice == nil)
        #expect(store.leftRunning == "sleep 40 still runs.")

        store.agentStatusChanged(to: .done)
        #expect(store.leftRunning == "sleep 40 still runs.")
        store.agentStatusChanged(to: .working)
        #expect(store.leftRunning == nil)
    }

    /// A newer tap's word wins over what an older Stop left running, and
    /// clears what one already said.
    @Test func aNewerTapOverridesWhatAnOlderStopLeftRunning() async {
        let store = AgentComposerStopStore(sleep: { _ in })
        await store.stop(using: { .sentLeavingWork("first") })?.value
        #expect(store.leftRunning == "first")

        let older = ScriptedTransportCallGate()
        let late = store.stop(using: {
            await older.waitUntilOpen()
            return .sentLeavingWork("older")
        })
        #expect(store.leftRunning == nil)
        await older.waitForEntry()
        store.agentStatusChanged(to: .idle)
        await store.stop(using: { .sent })?.value
        await older.open()
        await late?.value
        #expect(store.leftRunning == nil)
    }

    /// Esc keeps no gap: once a status change readies Stop, the next tap
    /// presses at once, even while the last Esc is still on its way.
    @Test func anEscTapAfterAStatusChangePressesWhileTheLastEscIsOnItsWay() async {
        let send = ScriptedTransportCallGate()
        let store = AgentComposerStopStore(sleep: { _ in })
        let esc = EscRecorder()

        let first = store.stop(using: {
            let outcome = await esc.press()
            await send.waitUntilOpen()
            return outcome
        })
        await send.waitForEntry()
        store.agentStatusChanged(to: .done)
        #expect(store.phase == .ready)

        let second = store.stop(using: { await esc.press() })
        #expect(second != nil)
        await second?.value
        #expect(esc.count == 2, "the second Esc went while the first was still on its way")

        await send.open()
        await first?.value
        #expect(esc.count == 2)
    }

    @Test func aStopWaitsItsOwnWindowAndSaysItsOwnNotice() async {
        let sleeps = SleepRecorder()
        let store = AgentComposerStopStore(sleep: { await sleeps.record($0) })

        await store.stop(using: { .sent })?.value
        #expect(await sleeps.durations == [.seconds(3)])
        #expect(store.notice == "Esc went, but the Agent still shows Working.")

        let keys = AgentStopWait(
            window: .seconds(5), unconfirmedNotice: "Keys went, but the Agent still shows Working.")
        await store.stop(waiting: keys, using: { .sent })?.value
        #expect(await sleeps.durations == [.seconds(3), .seconds(5)])
        #expect(store.notice == "Keys went, but the Agent still shows Working.")
    }

    /// The terminal's Stop: Esc's 3 s window and notice with no gap, Esc's
    /// hint, and the surface's own press.
    @Test func anEscapeInterruptCarriesEscsWaitAndHint() async {
        let interrupt = AgentComposerInterrupt.escape { .failed("The surface's own press.") }

        #expect(
            interrupt.wait
                == AgentStopWait(
                    window: .seconds(3), unconfirmedNotice: "Esc went, but the Agent still shows Working.",
                    minimumGap: .zero))
        #expect(interrupt.accessibilityHint == "Presses Esc to interrupt the Agent")
        #expect(await interrupt.perform() == .failed("The surface's own press."))
    }

    /// Esc only shows a toast in Grok Build, whose turns stop with Ctrl+C,
    /// so its terminal Composer keeps Send. Every other kind presses Esc.
    @Test func theTerminalStopIsEscOutsideGrokBuild() async {
        let grok = AgentComposerInterrupt.terminal(forAgentKind: "grok") { .sent }
        #expect(grok == nil)

        for kind in ["claude", "codex", "pi", "omp", "opencode", "agy", "an-unknown-agent"] {
            let interrupt = AgentComposerInterrupt.terminal(forAgentKind: kind) { .failed("The surface's own press.") }
            #expect(interrupt?.wait == .escape, "\(kind)")
            #expect(interrupt?.accessibilityHint == AgentComposerInterrupt.escapeHint, "\(kind)")
            #expect(await interrupt?.perform() == .failed("The surface's own press."), "\(kind)")
        }
    }

    @Test func aStopIgnoresTapsInsideItsMinimumGapAcrossStatusChanges() async {
        let window = ScriptedTransportCallGate()
        let clock = StopClock()
        let start = clock.now
        let store = AgentComposerStopStore(
            sleep: { _ in await window.waitUntilOpen() }, now: { clock.now })
        let presses = EscRecorder()

        let first = store.stop(waiting: Self.gapped, using: { await presses.press() })
        await window.waitForEntry()
        store.agentStatusChanged(to: .done)

        clock.now = start + .milliseconds(500)
        #expect(store.stop(waiting: Self.gapped, using: { await presses.press() }) == nil)
        #expect(presses.count == 1)
        #expect(store.phase == .ready, "an ignored tap leaves Stop as it was")

        clock.now = start + .milliseconds(1600)
        let second = store.stop(waiting: Self.gapped, using: { await presses.press() })
        #expect(second != nil)
        await window.waitForEntry(count: 2)
        #expect(presses.count == 2)

        await window.open()
        await first?.value
        await second?.value
    }

    @Test func aGappedStopIgnoresTapsWhileAnAttemptIsOnItsWay() async {
        let send = ScriptedTransportCallGate()
        let clock = StopClock()
        let start = clock.now
        let store = AgentComposerStopStore(sleep: { _ in }, now: { clock.now })
        let presses = EscRecorder()

        let first = store.stop(waiting: Self.gapped, using: {
            let outcome = await presses.press()
            await send.waitUntilOpen()
            return outcome
        })
        await send.waitForEntry()
        store.agentStatusChanged(to: .done)
        #expect(store.phase == .ready)

        clock.now = start + .seconds(2)
        #expect(store.stop(waiting: Self.gapped, using: { await presses.press() }) == nil)

        // The attempt ends once its keys have gone, here at +2 s.
        await send.open()
        await first?.value
        clock.now = start + .milliseconds(2500)
        #expect(store.stop(waiting: Self.gapped, using: { await presses.press() }) == nil)
        #expect(presses.count == 1)

        clock.now = start + .milliseconds(3600)
        await store.stop(waiting: Self.gapped, using: { await presses.press() })?.value
        #expect(presses.count == 2)
    }

    @Test func anIgnoredTapKeepsTheRunningStopsWaitAndNotice() async {
        let window = ScriptedTransportCallGate()
        let sleeps = SleepRecorder()
        let store = AgentComposerStopStore(sleep: { duration in
            await sleeps.record(duration)
            await window.waitUntilOpen()
        })
        let running = AgentStopWait(
            window: .seconds(5), unconfirmedNotice: "The running stop's notice.")
        let ignored = AgentStopWait(
            window: .seconds(7), unconfirmedNotice: "The ignored tap's notice.")
        let ignoredPresses = EscRecorder()

        let wait = store.stop(waiting: running, using: { .sent })
        await window.waitForEntry()
        #expect(store.stop(waiting: ignored, using: { await ignoredPresses.press() }) == nil)

        await window.open()
        await wait?.value
        #expect(ignoredPresses.count == 0)
        #expect(store.phase == .unconfirmed)
        #expect(store.notice == "The running stop's notice.")
        #expect(await sleeps.durations == [.seconds(5)])
    }

    /// A wait with a gap, as a program whose second press could quit it.
    private static let gapped = AgentStopWait(
        window: .seconds(3), unconfirmedNotice: "Keys went, but the Agent still shows Working.",
        minimumGap: .milliseconds(1500))
}

/// Stop belongs to the Agent's Composer store, not to a view: its status
/// stream ends the wait with no Composer on screen, and its sends hold
/// Stop back.
@MainActor
@Suite("Agent Composer Stop, per Agent")
struct AgentComposerStopOwnershipTests {
    @Test func theAgentsStatusEndsTheWaitWithNoComposerOnScreen() async {
        let window = ScriptedTransportCallGate()
        let (updates, continuation) = AsyncStream.makeStream(
            of: ConsoleStore.AgentStatusUpdate.self)
        defer { continuation.finish() }
        let composer = AgentComposerStore(
            target: "w1:p1", initialStatus: .working, statusUpdates: updates,
            stop: AgentComposerStopStore(sleep: { _ in await window.waitUntilOpen() })
        ) { _ in throw TransportError.cancelled }
        composer.open()

        let wait = composer.stop.stop(using: { .sent })
        await window.waitForEntry()
        #expect(composer.stop.isStopping)

        continuation.yield(.init(status: .idle, liveUpdatesAvailable: true))
        #expect(await Self.eventually { composer.stop.phase == .ready })
        await window.open()
        await wait?.value
        #expect(composer.stop.phase == .ready)
    }

    @Test func sendingHoldsStopBack() async {
        let hold = ScriptedTransportCallGate()
        let composer = AgentComposerStore(
            target: "w1:p1", initialStatus: .working,
            stop: AgentComposerStopStore(sleep: { _ in await hold.waitUntilOpen() })
        ) { _ in throw TransportError.cancelled }
        composer.replaceDraft(with: "and run the tests")

        let send = Task { await composer.send() }
        await hold.waitForEntry()
        #expect(composer.draft.isEmpty)
        #expect(composer.stop.isHeldAfterSend)

        await hold.open()
        _ = await send.value
        #expect(await Self.eventually { !composer.stop.isHeldAfterSend })
    }

    private static func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

@MainActor
private final class EscRecorder {
    var count = 0
    var outcome: AgentInterruptOutcome = .sent

    func press() async -> AgentInterruptOutcome {
        count += 1
        return outcome
    }
}

/// How long each of Stop's waits asked to sleep; the terminal's Stop in
/// `AgentDirectInputTests` records its wait too.
actor SleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

/// Stop's clock, moved by hand.
private final class StopClock: @unchecked Sendable {
    var now = ContinuousClock.now
}

/// Hands each sleep the next gate, so overlapping waits end one by one.
@MainActor
private final class GateQueue {
    private let gates: [ScriptedTransportCallGate]
    private var index = 0

    init(_ gates: [ScriptedTransportCallGate]) {
        self.gates = gates
    }

    func next() -> ScriptedTransportCallGate {
        defer { index += 1 }
        return gates[index]
    }
}
