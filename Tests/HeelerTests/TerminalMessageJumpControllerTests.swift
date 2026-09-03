import Foundation
import Testing

@testable import Heeler

@Suite("Terminal message jump controller")
@MainActor
struct TerminalMessageJumpControllerTests {
    @Test("finds a match several steps away")
    func findsMatchSeveralStepsAway() async {
        let harness = JumpHarness(script: ["a", "b", "c", "MATCH", "e"], matchExact: "MATCH")
        harness.seedFrame("start")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(harness.stepCalls.count == 4)
        #expect(harness.stepCalls.allSatisfy { $0.direction == .older })
        // Two fine steps, then the ramp opens up on the third.
        #expect(harness.stepCalls.map(\.rows) == [8, 8, 16, 16])
        #expect(!harness.controller.isRunning)
    }

    /// A message far above must be reachable in one press, not a crawl. The
    /// step grows geometrically once the fine steps are spent, and never
    /// exceeds the viewport -- a larger step would scroll rows past without
    /// rendering them, and a message in that gap would be missed.
    @Test("step size ramps up to the viewport and stops there")
    func stepSizeRampsToTheViewport() async {
        let harness = JumpHarness(script: [], deliverFrames: false, viewportRows: 34)

        #expect((0..<9).map { harness.controller.rows(forStep: $0) }
            == [8, 8, 16, 32, 32, 32, 32, 32, 32])

        // Reach of one press, versus 240 rows before the ramp existed.
        let reach = (0..<harness.controller.configuration.maxSteps)
            .reduce(0) { $0 + harness.controller.rows(forStep: $1) }
        #expect(reach > 1700)
    }

    /// Before the surface reports metrics there is no viewport to size from,
    /// so the ramp stops at a ceiling short enough for any plausible grid.
    @Test("unknown viewport caps the ramp conservatively")
    func unknownViewportCapsTheRamp() async {
        let harness = JumpHarness(script: [], deliverFrames: false)

        #expect((0..<7).map { harness.controller.rows(forStep: $0) }
            == [8, 8, 16, 16, 16, 16, 16])
    }

    /// The entry frame's own message must not end the jump, however many
    /// frames it stays visible for — only a message that was not on screen at
    /// the press does.
    @Test("a message already on screen at the press does not end the jump")
    func walksPastEntryMatch() async {
        let harness = JumpHarness(
            script: ["MSG1-scrolled", "MSG1-lower", "MSG2"],
            keys: { frame in
                frame.hasPrefix("MSG") ? [String(frame.prefix(4))] : []
            }
        )
        harness.seedFrame("MSG1")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(harness.stepCalls.count == 3)
        #expect(harness.lastDeliveredFrame == "MSG2")
        #expect(!harness.controller.isRunning)
    }

    /// The defect Round 1 of testloop found on a live Grok TUI: several
    /// messages share the viewport, so requiring the screen to be free of
    /// messages before hunting the next one scrolled past every one of them.
    @Test("stops at the neighbour even while earlier messages stay on screen")
    func stopsAtNeighbourSharingTheViewport() async {
        let harness = JumpHarness(
            // Every frame still shows MSG3; MSG2 scrolls in alongside it.
            script: ["MSG3", "MSG3 MSG2"],
            keys: { frame in
                Set(frame.split(separator: " ").map(String.init))
            }
        )
        harness.seedFrame("MSG3")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(harness.stepCalls.count == 2)
        #expect(harness.lastDeliveredFrame == "MSG3 MSG2")
    }

    @Test("identical frames reach end at unchangedFramesBeforeEnd")
    func reachedEndOnIdenticalFrames() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.unchangedFramesBeforeEnd = 2
        configuration.maxSteps = 10

        let harness = JumpHarness(
            script: ["same", "same", "same"],
            configuration: configuration,
            matchExact: "never"
        )
        harness.seedFrame("same")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .reachedEnd)
        #expect(harness.stepCalls.count == 2)
        #expect(!harness.controller.isRunning)
    }

    @Test("exhausts exactly at maxSteps when frames keep changing")
    func exhaustsAtMaxSteps() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 3
        configuration.unchangedFramesBeforeEnd = 5

        let harness = JumpHarness(
            script: ["1", "2", "3", "4", "5"],
            configuration: configuration,
            matchExact: "never"
        )
        harness.seedFrame("0")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .exhausted)
        #expect(harness.stepCalls.count == 3)
        #expect(!harness.controller.isRunning)
    }

    @Test("cancel mid-jump returns cancelled and stops stepping")
    func cancelMidJump() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 20
        configuration.frameSettleTimeout = .seconds(60)

        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "never",
            deliverFrames: false,
            sleep: { try await Task.sleep(for: $0) }
        )
        harness.seedFrame("start")

        let jumpTask = Task { @MainActor in
            await harness.controller.jump(.older)
        }

        await waitUntil { harness.stepCalls.count == 1 }
        #expect(harness.controller.isRunning)

        harness.controller.cancel()
        let outcome = await jumpTask.value

        #expect(outcome == .cancelled)
        #expect(harness.stepCalls.count == 1)
        #expect(!harness.controller.isRunning)
    }

    @Test("settle timeout with no frame counts toward reachedEnd")
    func settleTimeoutCountsAsUnchanged() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.unchangedFramesBeforeEnd = 2
        configuration.maxSteps = 10
        configuration.frameSettleTimeout = .milliseconds(1)

        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "never",
            deliverFrames: false,
            sleep: { _ in }
        )
        harness.seedFrame("frozen")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .reachedEnd)
        #expect(harness.stepCalls.count == 2)
        #expect(!harness.controller.isRunning)
    }

    @Test("extra frameDidChange calls between steps do not desynchronise")
    func burstFramesDoNotDesynchronise() async {
        let driver = BurstJumpDriver(
            bursts: [
                ["noise-a", "noise-b", "1"],
                ["noise-c", "TARGET"],
            ],
            keys: { $0 == "TARGET" ? ["TARGET"] : [] }
        )
        driver.seedFrame("0")

        let outcome = await driver.controller.jump(.older)

        #expect(outcome == .found)
        #expect(driver.stepCount == 2)
        #expect(!driver.controller.isRunning)
    }

    @Test("post-arm burst uses the latest frame not the first paint")
    func postArmBurstUsesLatestFrame() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 5
        configuration.frameSettleTimeout = .seconds(60)

        let arm = WaitArmSignal()
        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "TARGET",
            deliverFrames: false,
            sleep: { duration in
                await arm.markArmed()
                try await Task.sleep(for: duration)
            }
        )
        harness.seedFrame("start")

        let jumpTask = Task { @MainActor in
            await harness.controller.jump(.older)
        }
        await arm.waitUntilArmed()

        // Same MainActor turn: first paint wakes the waiter, second is the real frame.
        harness.controller.frameDidChange("partial")
        harness.controller.frameDidChange("TARGET")

        let outcome = await jumpTask.value
        #expect(outcome == .found)
        #expect(harness.stepCalls.count == 1)
        #expect(!harness.controller.isRunning)
    }

    @Test("frame then cancel returns cancelled not found")
    func frameThenCancelReturnsCancelled() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 5
        configuration.frameSettleTimeout = .seconds(60)

        let arm = WaitArmSignal()
        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "MATCH",
            deliverFrames: false,
            sleep: { duration in
                await arm.markArmed()
                try await Task.sleep(for: duration)
            }
        )
        harness.seedFrame("start")

        let jumpTask = Task { @MainActor in
            await harness.controller.jump(.older)
        }
        await arm.waitUntilArmed()

        harness.controller.frameDidChange("MATCH")
        harness.controller.cancel()

        let outcome = await jumpTask.value
        #expect(outcome == .cancelled)
        #expect(harness.stepCalls.count == 1)
        #expect(!harness.controller.isRunning)
    }

    @Test("cancelling the enclosing task returns cancelled")
    func enclosingTaskCancelReturnsCancelled() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 5
        configuration.frameSettleTimeout = .seconds(60)

        let arm = WaitArmSignal()
        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "never",
            deliverFrames: false,
            sleep: { duration in
                await arm.markArmed()
                try await Task.sleep(for: duration)
            }
        )
        harness.seedFrame("start")

        let jumpTask = Task { @MainActor in
            await harness.controller.jump(.older)
        }
        await arm.waitUntilArmed()
        #expect(harness.controller.isRunning)

        jumpTask.cancel()
        let outcome = await jumpTask.value

        #expect(outcome == .cancelled)
        #expect(harness.stepCalls.count == 1)
        #expect(!harness.controller.isRunning)
    }

    @Test("stale enclosing-task cancel does not poison the next jump")
    func staleTaskCancelDoesNotPoisonNextJump() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 5
        configuration.frameSettleTimeout = .seconds(60)

        let arm = WaitArmSignal()
        let seams = CancelHandlerSeams()
        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "TARGET",
            deliverFrames: false,
            sleep: { duration in
                await arm.markArmed()
                try await Task.sleep(for: duration)
            }
        )
        // Seam 1 holds H until B's waiter is armed. Seam 2 fires on the
        // MainActor only after H has executed the wait-id / flag region.
        harness.controller.enclosingCancelHandlerBarrier = {
            await seams.waitUntilReleased()
        }
        harness.controller.enclosingCancelHandlerDidPassPoisonWindow = {
            seams.notePoisonWindowPassed()
        }
        harness.seedFrame("start")

        let jumpA = Task { @MainActor in
            await harness.controller.jump(.older)
        }
        await arm.waitUntilArmed()

        // Clear A's wait id with a frame, then cancel the enclosing task so its
        // handler is scheduled against a gone waiter and parks on seam 1.
        harness.controller.frameDidChange("not-the-target")
        jumpA.cancel()
        let outcomeA = await jumpA.value
        #expect(outcomeA == .cancelled)
        #expect(!harness.controller.isRunning)

        await arm.reset()

        let jumpB = Task { @MainActor in
            await harness.controller.jump(.older)
        }
        await arm.waitUntilArmed()

        // B's waiter is live. Release seam 1, then wait on seam 2 — which is
        // call-position proof that H ran the poison window on this MainActor.
        await seams.release()
        await seams.waitUntilPoisonWindowPassed()

        harness.controller.frameDidChange("TARGET")
        let outcomeB = await jumpB.value

        #expect(outcomeB == .found)
        #expect(harness.stepCalls.count == 2)
        #expect(!harness.controller.isRunning)
    }

    @Test("returnToLive ignores messages and stops on unchanged frames")
    func returnToLiveIgnoresMatches() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.unchangedFramesBeforeEnd = 2

        // live-2 repeats once after the first live-2 observation, which is
        // unchangedCount=1; the harness re-delivers the last frame for the
        // next step to hit unchangedFramesBeforeEnd=2.
        let harness = JumpHarness(
            script: ["live-1", "live-2", "live-2"],
            configuration: configuration,
            keys: { [$0] }
        )
        harness.seedFrame("start")

        let outcome = await harness.controller.returnToLive()

        #expect(outcome == .reachedEnd)
        #expect(harness.stepCalls.count == 4)
        #expect(harness.stepCalls.allSatisfy { $0.direction == .newer })
        #expect(!harness.controller.isRunning)
    }

    @Test("isRunning is true during jump and false after including cancel")
    func isRunningLifecycle() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.frameSettleTimeout = .seconds(60)

        let harness = JumpHarness(
            script: ["x"],
            configuration: configuration,
            matchExact: "never",
            deliverFrames: false,
            sleep: { try await Task.sleep(for: $0) }
        )
        harness.seedFrame("start")
        #expect(!harness.controller.isRunning)

        let jumpTask = Task { @MainActor in
            await harness.controller.jump(.newer)
        }
        await waitUntil { harness.controller.isRunning }
        #expect(harness.controller.isRunning)

        harness.controller.cancel()
        let outcome = await jumpTask.value
        #expect(outcome == .cancelled)
        #expect(!harness.controller.isRunning)
    }

    @Test("second jump while running is refused without interrupting the first")
    func refusesReentrancy() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.frameSettleTimeout = .seconds(60)

        let harness = JumpHarness(
            script: [],
            configuration: configuration,
            matchExact: "never",
            deliverFrames: false,
            sleep: { try await Task.sleep(for: $0) }
        )
        harness.seedFrame("start")

        let first = Task { @MainActor in
            await harness.controller.jump(.older)
        }
        await waitUntil { harness.stepCalls.count == 1 }

        let second = await harness.controller.jump(.newer)
        #expect(second == .cancelled)
        #expect(harness.stepCalls.count == 1)

        harness.controller.cancel()
        let firstOutcome = await first.value
        #expect(firstOutcome == .cancelled)
        #expect(!harness.controller.isRunning)
    }

    /// Live Grok conversation, oldest to newest: `/resume-claude …` then
    /// `/handoff`. At live bottom the current prompt is already visible
    /// because Grok pins it. Neighbor appearance therefore walks to the older
    /// prompt. Sticky overshoot reverses to the `/handoff` turn boundary.
    @Test("Grok sticky prompt overshoots then reverses to the current turn")
    func grokStickyPromptReversesToCurrentTurnBoundary() async {
        let index = AttachUserMessageIndex()
        #expect(index.visibleMessageKeys(GrokStickyFrames.liveBottom)
            == [GrokStickyFrames.handoffKey])
        #expect(index.visibleMessageKeys(GrokStickyFrames.handoffScrolled)
            == [GrokStickyFrames.handoffKey])
        #expect(index.visibleMessageKeys(GrokStickyFrames.resumeClaude)
            == [GrokStickyFrames.resumeKey])

        let harness = JumpHarness(
            script: GrokStickyFrames.liveToResume,
            policy: .stickyPromptOvershoot,
            keys: { index.visibleMessageKeys($0) },
            bidirectional: true
        )
        harness.seedCurrentFrame()

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(
            index.visibleMessageKeys(harness.lastDeliveredFrame ?? "")
                == [GrokStickyFrames.handoffKey])
        #expect(harness.lastDeliveredFrame != GrokStickyFrames.resumeClaude)
        #expect(harness.stepCalls.map(\.direction) == [.older, .older, .newer])
        #expect(harness.stepCalls.map(\.rows) == [8, 8, 1])
        #expect(!harness.controller.isRunning)
    }

    /// The live Grok viewport indents its pinned prompt by five columns.
    /// This exact shape used to fall outside prompt recognition, so the first
    /// Up walked to `/resume-claude` instead of returning to `/handoff`.
    @Test("live Grok indentation still lands first Up on the current turn")
    func liveGrokIndentationLandsOnCurrentTurn() async {
        let profile = AgentMessageJumpProfile.forAgentKind("grok")
        let index = AttachUserMessageIndex(
            maximumPromptIndent: profile.maximumPromptIndent)
        let frames = [
            GrokStickyFrames.frame(
                prompt: GrokStickyFrames.handoffPrompt,
                body: "The live bottom.",
                promptIndent: 5),
            GrokStickyFrames.frame(
                prompt: GrokStickyFrames.handoffPrompt,
                body: "Earlier in the same turn.",
                promptIndent: 5),
            GrokStickyFrames.frame(
                prompt: GrokStickyFrames.resumePrompt,
                body: "The previous turn.",
                promptIndent: 5),
        ]
        let harness = JumpHarness(
            script: frames,
            policy: profile.policy,
            keys: { index.visibleMessageKeys($0) },
            bidirectional: true
        )
        harness.seedCurrentFrame()

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(
            index.visibleMessageKeys(harness.lastDeliveredFrame ?? "")
                == [GrokStickyFrames.handoffKey])
        #expect(harness.lastDeliveredFrame != frames.last)
        #expect(harness.stepCalls.contains { $0.direction == .newer })
    }

    /// The same captured frames under the default policy keep the behavior
    /// that #268's Grok defect exhibited: the already-visible `/handoff` is
    /// ignored and the walk stops on `/resume-claude`.
    @Test("standard policy still skips the sticky Grok prompt")
    func standardPolicySkipsStickyGrokPrompt() async {
        let index = AttachUserMessageIndex()
        let harness = JumpHarness(
            script: GrokStickyFrames.liveToResume,
            policy: .neighborAppearance,
            keys: { index.visibleMessageKeys($0) },
            bidirectional: true
        )
        harness.seedCurrentFrame()

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(
            index.visibleMessageKeys(harness.lastDeliveredFrame ?? "")
                == [GrokStickyFrames.resumeKey])
        #expect(harness.stepCalls.allSatisfy { $0.direction == .older })
        #expect(!harness.stepCalls.contains { $0.direction == .newer })
    }

    /// After the first Up has landed on `/handoff`, the next press is already
    /// at that turn's boundary. The first moved frame is `/resume-claude`, so
    /// sticky overshoot must not reverse back onto `/handoff`.
    @Test("repeated Up from the Grok turn boundary lands on the older prompt")
    func grokStickyRepeatedUpLandsOnOlderTurn() async {
        let index = AttachUserMessageIndex()
        let harness = JumpHarness(
            script: GrokStickyFrames.liveToResume,
            policy: .stickyPromptOvershoot,
            keys: { index.visibleMessageKeys($0) },
            bidirectional: true,
            startAt: 1
        )
        harness.seedCurrentFrame()

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(
            index.visibleMessageKeys(harness.lastDeliveredFrame ?? "")
                == [GrokStickyFrames.resumeKey])
        #expect(harness.stepCalls.allSatisfy { $0.direction == .older })
        #expect(!harness.stepCalls.contains { $0.direction == .newer })
    }

    /// Down keeps neighbor appearance even under the sticky policy, so a
    /// walk toward live does not reverse older.
    @Test("sticky policy Down still stops on a newly appearing prompt")
    func stickyPolicyDownUsesNeighborAppearance() async {
        let index = AttachUserMessageIndex()
        let harness = JumpHarness(
            script: GrokStickyFrames.liveToResume,
            policy: .stickyPromptOvershoot,
            keys: { index.visibleMessageKeys($0) },
            bidirectional: true,
            startAt: 2
        )
        harness.seedCurrentFrame()

        let outcome = await harness.controller.jump(.newer)

        #expect(outcome == .found)
        #expect(
            index.visibleMessageKeys(harness.lastDeliveredFrame ?? "")
                == [GrokStickyFrames.handoffKey])
        #expect(harness.stepCalls.allSatisfy { $0.direction == .newer })
    }

    @Test("cancel during sticky reverse returns cancelled")
    func cancelDuringStickyReverse() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 20
        configuration.frameSettleTimeout = .seconds(60)

        let index = AttachUserMessageIndex()
        let arm = WaitArmSignal()
        let harness = JumpHarness(
            script: GrokStickyFrames.liveToResume,
            configuration: configuration,
            policy: .stickyPromptOvershoot,
            keys: { index.visibleMessageKeys($0) },
            bidirectional: true,
            deliverNewerFrames: false,
            sleep: { duration in
                await arm.markArmed()
                try await Task.sleep(for: duration)
            }
        )
        harness.seedCurrentFrame()

        let jumpTask = Task { @MainActor in
            await harness.controller.jump(.older)
        }
        await arm.waitUntilArmed()
        #expect(harness.controller.isRunning)
        #expect(harness.stepCalls.map(\.direction) == [.older, .older, .newer])

        harness.controller.cancel()
        let outcome = await jumpTask.value

        #expect(outcome == .cancelled)
        #expect(harness.stepCalls.count == 3)
        #expect(!harness.controller.isRunning)
    }

    /// Once reverse starts, identical frames mean the TUI cannot move newer.
    /// That is an end, not a cue to walk older again.
    @Test("sticky reverse stops on unchanged frames without oscillating")
    func stickyReverseReachedEndDoesNotOscillate() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.unchangedFramesBeforeEnd = 2

        let index = AttachUserMessageIndex()
        let harness = JumpHarness(
            script: [
                GrokStickyFrames.handoffScrolled,
                GrokStickyFrames.resumeClaude,
            ],
            configuration: configuration,
            policy: .stickyPromptOvershoot,
            keys: { index.visibleMessageKeys($0) }
        )
        harness.seedFrame(GrokStickyFrames.liveBottom)

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .reachedEnd)
        #expect(harness.stepCalls.map(\.direction) == [.older, .older, .newer, .newer])
        let reverse = harness.stepCalls.drop { $0.direction == .older }
        #expect(reverse.allSatisfy { $0.direction == .newer && $0.rows == 1 })
        #expect(!harness.controller.isRunning)
    }

    /// One older request is not one observed row. After an 8-row overshoot
    /// the reverse still has to walk frame-by-frame; it must not stop at 8
    /// one-row steps if `/handoff` has not come back yet.
    @Test("sticky reverse keeps going past the overshoot row count until the anchor returns")
    func stickyReverseFindsAnchorAfterMoreStepsThanOvershootRows() async {
        let index = AttachUserMessageIndex()
        let overshootRows = 8
        let reverseFramesBeforeAnchor = overshootRows + 4
        let stillOnResume = (1...reverseFramesBeforeAnchor).map { n in
            GrokStickyFrames.frame(
                prompt: GrokStickyFrames.resumePrompt,
                body: "coalesced older paint \(n); the pinned prompt has not returned")
        }
        let harness = JumpHarness(
            script: [GrokStickyFrames.handoffScrolled, GrokStickyFrames.resumeClaude]
                + stillOnResume
                + [GrokStickyFrames.handoffScrolled],
            policy: .stickyPromptOvershoot,
            keys: { index.visibleMessageKeys($0) }
        )
        harness.seedFrame(GrokStickyFrames.liveBottom)

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(
            index.visibleMessageKeys(harness.lastDeliveredFrame ?? "")
                == [GrokStickyFrames.handoffKey])
        #expect(harness.stepCalls.prefix(2).map(\.direction) == [.older, .older])
        #expect(harness.stepCalls.prefix(2).map(\.rows) == [overshootRows, overshootRows])
        let reverse = Array(harness.stepCalls.dropFirst(2))
        #expect(reverse.count == reverseFramesBeforeAnchor + 1)
        #expect(reverse.count > overshootRows)
        #expect(reverse.allSatisfy { $0.direction == .newer && $0.rows == 1 })
        #expect(!harness.controller.isRunning)
    }

    /// Reverse that never recovers the anchor is bounded by the remaining
    /// total step budget, not by the last older request's row count.
    @Test("sticky reverse exhausts the shared maxSteps budget without oscillating")
    func stickyReverseExhaustsSharedMaxStepsWithoutOscillating() async {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 12

        let index = AttachUserMessageIndex()
        let extras = (1...20).map { n in
            GrokStickyFrames.frame(
                prompt: GrokStickyFrames.resumePrompt,
                body: "older body still showing the previous prompt \(n)")
        }
        let harness = JumpHarness(
            script: [GrokStickyFrames.handoffScrolled, GrokStickyFrames.resumeClaude]
                + extras,
            configuration: configuration,
            policy: .stickyPromptOvershoot,
            keys: { index.visibleMessageKeys($0) }
        )
        harness.seedFrame(GrokStickyFrames.liveBottom)

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .exhausted)
        #expect(harness.stepCalls.count == 12)
        #expect(harness.stepCalls.prefix(2).allSatisfy { $0.direction == .older })
        let reverse = harness.stepCalls.dropFirst(2)
        #expect(reverse.count == 10)
        #expect(reverse.count > harness.stepCalls[1].rows)
        #expect(reverse.allSatisfy { $0.direction == .newer && $0.rows == 1 })
        #expect(!harness.stepCalls.dropFirst(2).contains { $0.direction == .older })
        #expect(!harness.controller.isRunning)
    }

    @Test("sticky policy with no entry prompt falls back to neighbor appearance")
    func stickyPolicyEmptyEntryFallsBackToNeighbor() async {
        let index = AttachUserMessageIndex()
        let harness = JumpHarness(
            script: [GrokStickyFrames.liveBottom],
            policy: .stickyPromptOvershoot,
            keys: { index.visibleMessageKeys($0) }
        )
        harness.seedFrame("no prompt on this frame at all")

        let outcome = await harness.controller.jump(.older)

        #expect(outcome == .found)
        #expect(
            index.visibleMessageKeys(harness.lastDeliveredFrame ?? "")
                == [GrokStickyFrames.handoffKey])
        #expect(harness.stepCalls.allSatisfy { $0.direction == .older })
    }
}

// MARK: - Harness

/// Signals when the injected settle-timeout sleep has started — at that point
/// the frame waiter is armed.
private actor WaitArmSignal {
    private var isArmed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markArmed() {
        isArmed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func reset() {
        isArmed = false
    }

    func waitUntilArmed() async {
        if isArmed { return }
        await withCheckedContinuation { continuation in
            if isArmed {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

/// Two call-position seams for the stale cancel-handler regression.
///
/// Seam 1 (`waitUntilReleased`) parks H before the poison window. Seam 2
/// (`notePoisonWindowPassed`) is invoked synchronously from the MainActor
/// handler *after* that window, so awaiting it proves H ran the guard/write
/// region — not merely that a barrier actor released.
@MainActor
private final class CancelHandlerSeams {
    private var released = false
    private var poisonWindowPassed = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var poisonWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.released {
                continuation.resume()
            } else {
                self.releaseWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func notePoisonWindowPassed() {
        poisonWindowPassed = true
        let pending = poisonWaiters
        poisonWaiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitUntilPoisonWindowPassed() async {
        if poisonWindowPassed { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.poisonWindowPassed {
                continuation.resume()
            } else {
                self.poisonWaiters.append(continuation)
            }
        }
    }
}

@MainActor
private final class BurstJumpDriver {
    private var bursts: [[String]]
    private var controllerStorage: TerminalMessageJumpController!
    private(set) var stepCount = 0

    var controller: TerminalMessageJumpController { controllerStorage }

    init(
        bursts: [[String]],
        keys: @escaping @MainActor (String) -> Set<String>
    ) {
        self.bursts = bursts
        controllerStorage = TerminalMessageJumpController(
            step: { [weak self] _, _ in
                self?.deliverNextBurst()
            },
            visibleMessages: keys,
            sleep: { _ in }
        )
    }

    func seedFrame(_ text: String) {
        controller.frameDidChange(text)
    }

    private func deliverNextBurst() {
        stepCount += 1
        guard !bursts.isEmpty else { return }
        let burst = bursts.removeFirst()
        for frame in burst {
            controller.frameDidChange(frame)
        }
    }
}

@MainActor
private final class JumpHarness {
    struct StepCall {
        var direction: TerminalMessageJumpController.Direction
        var rows: Int
    }

    private(set) var stepCalls: [StepCall] = []
    private(set) var lastDeliveredFrame: String?
    private let script: [String]
    private var scriptIndex = 0
    private var position: Int
    private let bidirectional: Bool
    private let deliverOlderFrames: Bool
    private let deliverNewerFrames: Bool
    private var controllerStorage: TerminalMessageJumpController!

    var controller: TerminalMessageJumpController { controllerStorage }

    init(
        script: [String],
        configuration: TerminalMessageJumpController.Configuration = .init(),
        policy: TerminalMessageJumpPolicy = .neighborAppearance,
        matchExact: String? = nil,
        deliverFrames: Bool = true,
        keys: (@MainActor (String) -> Set<String>)? = nil,
        viewportRows: Int? = nil,
        bidirectional: Bool = false,
        startAt: Int = 0,
        deliverNewerFrames: Bool = true,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) {
        self.script = script
        self.bidirectional = bidirectional
        self.position = if script.isEmpty {
            0
        } else {
            min(max(startAt, 0), script.count - 1)
        }
        self.deliverOlderFrames = deliverFrames
        self.deliverNewerFrames = deliverFrames && deliverNewerFrames

        let keyProvider: @MainActor (String) -> Set<String>
        if let keys {
            keyProvider = keys
        } else if let matchExact {
            keyProvider = { $0 == matchExact ? [matchExact] : [] }
        } else {
            keyProvider = { _ in [] }
        }

        controllerStorage = TerminalMessageJumpController(
            configuration: configuration,
            policy: policy,
            step: { [weak self] direction, rows in
                self?.noteStep(direction: direction, rows: rows)
            },
            visibleMessages: keyProvider,
            viewportRows: { viewportRows },
            sleep: sleep
        )
    }

    func seedFrame(_ text: String) {
        controller.frameDidChange(text)
    }

    func seedCurrentFrame() {
        guard script.indices.contains(position) else { return }
        lastDeliveredFrame = script[position]
        controller.frameDidChange(script[position])
    }

    private func noteStep(
        direction: TerminalMessageJumpController.Direction,
        rows: Int
    ) {
        stepCalls.append(StepCall(direction: direction, rows: rows))
        let shouldDeliver =
            switch direction {
            case .older: deliverOlderFrames
            case .newer: deliverNewerFrames
            }
        guard shouldDeliver else { return }

        if bidirectional {
            guard !script.isEmpty else { return }
            switch direction {
            case .older:
                if position + 1 < script.count { position += 1 }
            case .newer:
                if position > 0 { position -= 1 }
            }
            lastDeliveredFrame = script[position]
            controller.frameDidChange(script[position])
            return
        }

        let frame: String
        if scriptIndex < script.count {
            frame = script[scriptIndex]
            scriptIndex += 1
        } else if let last = lastDeliveredFrame {
            frame = last
        } else {
            frame = ""
        }
        lastDeliveredFrame = frame
        controller.frameDidChange(frame)
    }
}

/// Captured Grok frame shapes for the sticky-prompt walk. The live
/// conversation's user turns are `/resume-claude …` then `/handoff`; Grok
/// pins whichever turn currently owns the viewport at the top.
private enum GrokStickyFrames {
    static let resumePrompt =
        "/resume-claude f64ca968-bb43-41f5-a118-28d7b946fea0"
    static let handoffPrompt = "/handoff"

    static let handoffKey = "line:/handoff"
    static let resumeKey =
        "line:/resume-claude f64ca968-bb43-41f5-a118-28d7b946fea0"

    static func frame(prompt: String, body: String, promptIndent: Int = 0) -> String {
        let indentation = String(repeating: " ", count: promptIndent)
        return """
        \(indentation)❯ \(prompt)        2:41 PM
          \(body)
        ────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────
        """
    }

    static let liveBottom = frame(
        prompt: handoffPrompt,
        body: "The Host is live. Pairing finished and the jump control is next.")
    static let handoffScrolled = frame(
        prompt: handoffPrompt,
        body: "Earlier in the same turn; the prompt stays pinned at the top.")
    static let resumeClaude = frame(
        prompt: resumePrompt,
        body: "The previous turn. Crossing here changes the pinned prompt.")

    static let liveToResume = [liveBottom, handoffScrolled, resumeClaude]
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ predicate: @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !predicate() {
        if DispatchTime.now().uptimeNanoseconds > deadline {
            Issue.record("timed out waiting for condition")
            return
        }
        await Task.yield()
    }
}
