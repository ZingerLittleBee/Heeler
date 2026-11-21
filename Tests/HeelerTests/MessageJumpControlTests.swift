import Foundation
import Testing

@testable import Heeler

struct MessageJumpControlTests {
    @Test func shortTerminalKeepsJumpControlsAboveFloatingLinks() throws {
        let terminalSize = CGSize(width: 390, height: 180)
        let linksTop = terminalSize.height - 8 - MessageJumpControlView.buttonSize
        let frame = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize,
            chromeSize: CGSize(width: 44, height: 89),
            minimumBottomInset: MessageJumpControlView.buttonSize + 16))
        #expect(frame.maxY <= linksTop - 8)
        #expect(frame.minY >= 0)

        #expect(MessageJumpPlacement.frame(
            terminalSize: CGSize(width: 390, height: 100),
            chromeSize: CGSize(width: 44, height: 89),
            minimumBottomInset: MessageJumpControlView.buttonSize + 16) == nil)
    }

    /// The user can slide the chrome along the edge; 1 is the position it
    /// always had, 0 the terminal's top, and the band still bounds it.
    @Test func placementFrameSlidesAlongTheEdge() throws {
        let terminalSize = CGSize(width: 390, height: 400)
        let chromeSize = CGSize(width: 44, height: 89)
        let lowest = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize))
        let docked = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize, edgeFraction: 1))
        #expect(docked == lowest)
        #expect(lowest.maxX == terminalSize.width, "An edge tab docks flush against the edge")
        let top = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize, edgeFraction: 0))
        #expect(top.minY == 0)
        #expect(top.minX == lowest.minX)
        let halfway = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize, edgeFraction: 0.5))
        #expect(halfway.minY == lowest.minY / 2)
        #expect(MessageJumpPlacement.edgeTravel(
            terminalHeight: terminalSize.height, chromeHeight: chromeSize.height) == lowest.minY)
        let overshoot = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize, edgeFraction: 3))
        #expect(overshoot == lowest, "A fraction past the band is the band")
    }

    @Test func availabilityRequiresAlternateScreen() {
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: false,
                canScrollRemoteContent: true)
                == .hidden)
        // At live output only Up has somewhere to go.
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true)
                == MessageJumpControlAvailability(
                    showsOlder: true, showsNewer: false, isEnabled: true))
    }

    /// A direction with no valid destination is hidden, not disabled
    /// (issue #268): Down appears once the viewport has left live output and
    /// Up disappears once an older walk has run out of history. `refs #268`.
    @Test func availabilityOffersOnlyDirectionsWithSomewhereToGo() {
        var reach = MessageJumpReach()
        #expect(reach.canJumpOlder)
        #expect(!reach.canJumpNewer)

        reach.noteOlderJump(.found, movedViewport: true)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: reach)
                == MessageJumpControlAvailability(
                    showsOlder: true, showsNewer: true, isEnabled: true))

        reach.noteOlderJump(.reachedEnd, movedViewport: true)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: reach)
                == MessageJumpControlAvailability(
                    showsOlder: false, showsNewer: true, isEnabled: true))

        reach.noteNewerJump(.reachedEnd, movedViewport: true)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: reach)
                == MessageJumpControlAvailability(
                    showsOlder: true, showsNewer: false, isEnabled: true))
    }

    /// A conversation that fits the screen: Up finds nothing and moves
    /// nothing, so the viewport is still live and *both* buttons go. A new
    /// turn re-offers Up; one that lands while the viewport sits at the
    /// oldest message does not, because it arrives below. `refs #268`.
    @Test func reachHidesEverythingWhenNothingScrollsAndReoffersUpOnGrowth() {
        var reach = MessageJumpReach()
        reach.noteOlderJump(.reachedEnd, movedViewport: false)
        #expect(!reach.canJumpOlder)
        #expect(!reach.canJumpNewer)
        #expect(
            !MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: reach).isVisible)

        reach.noteConversationGrew()
        #expect(reach.canJumpOlder)
        #expect(!reach.canJumpNewer)

        var displaced = MessageJumpReach()
        displaced.noteOlderJump(.reachedEnd, movedViewport: true)
        displaced.noteConversationGrew()
        #expect(!displaced.canJumpOlder)
        #expect(displaced.canJumpNewer)
    }

    @Test func reachFollowsTouchScrollsAndKeepsExhaustedWalksOpen() {
        var reach = MessageJumpReach()
        reach.noteTouchScroll(towardOlderContent: true)
        #expect(reach.canJumpNewer)
        #expect(reach.canJumpOlder)

        reach.noteOlderJump(.reachedEnd, movedViewport: true)
        #expect(!reach.canJumpOlder)
        reach.noteTouchScroll(towardOlderContent: false)
        #expect(reach.canJumpOlder)

        // Running out of step budget proves nothing about either end.
        reach.noteOlderJump(.exhausted, movedViewport: true)
        #expect(reach.canJumpOlder)
        #expect(reach.canJumpNewer)
        reach.noteNewerJump(.exhausted, movedViewport: true)
        #expect(reach.canJumpOlder)
        #expect(reach.canJumpNewer)

        // A cancelled walk leaves the verdicts alone.
        var untouched = MessageJumpReach()
        untouched.noteOlderJump(.cancelled, movedViewport: false)
        #expect(untouched == MessageJumpReach())
    }

    /// `herdr terminal attach` always enters the alternate screen, so that
    /// flag says nothing about the application inside it. An application that
    /// never asked for mouse reporting — a plain shell — cannot be scrolled,
    /// and the fallback would feed it cursor keys. Hide the control rather
    /// than offer a button that types into the user's line. `refs #268`.
    @Test func availabilityRequiresAScrollableRemoteApplication() {
        #expect(
            !MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: false).isVisible)
        #expect(
            !MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: false).isEnabled)
    }

    /// A button that cannot act is hidden, never greyed: a jump in flight
    /// keeps only its own direction, as a spinner that takes no hit. The
    /// agent's status plays no part — a working agent can still be walked,
    /// it only makes the end of history harder to detect.
    @Test func availabilityKeepsOnlyTheWalkingDirectionWhileAJumpRuns() {
        var displaced = MessageJumpReach()
        displaced.noteOlderJump(.found, movedViewport: true)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: displaced,
                runningDirection: .newer)
                == MessageJumpControlAvailability(
                    showsOlder: false, showsNewer: true, isEnabled: false))
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: displaced,
                runningDirection: .older)
                == MessageJumpControlAvailability(
                    showsOlder: true, showsNewer: false, isEnabled: false))
    }

    @Test func placementFrameHidesChromeThatCannotFitAboveTheBand() {
        // 80-pt terminal, 72-pt chrome: available above the band is 60.
        let short = CGSize(width: 390, height: 80)
        #expect(
            MessageJumpPlacement.frame(
                terminalSize: short,
                chromeSize: CGSize(width: 44, height: 72)) == nil)
        #expect(
            !MessageJumpPlacement.sitsAboveBottomBand(
                terminalHeight: 80,
                controlHeight: 72,
                bottomInset: MessageJumpPlacement.bottomInset(terminalHeight: 80)))

        let tallEnough = CGSize(width: 390, height: 160)
        let fitted = MessageJumpPlacement.frame(
            terminalSize: tallEnough,
            chromeSize: CGSize(width: 44, height: 72))
        #expect(fitted != nil)
        if let fitted {
            #expect(
                MessageJumpPlacement.sitsAboveBottomBand(
                    terminalHeight: tallEnough.height,
                    controlHeight: fitted.height,
                    bottomInset: MessageJumpPlacement.bottomInset(
                        terminalHeight: tallEnough.height)))
        }

        // Narrow surface: notice wider than the terminal cannot produce a
        // negative x origin — the frame is rejected instead.
        #expect(
            MessageJumpPlacement.frame(
                terminalSize: CGSize(width: 40, height: 400),
                chromeSize: CGSize(width: 120, height: 36))
                != nil)
        let narrowFrame = MessageJumpPlacement.frame(
            terminalSize: CGSize(width: 40, height: 400),
            chromeSize: CGSize(width: 120, height: 36))
        #expect(narrowFrame?.origin.x == 0)
        #expect(narrowFrame?.width == 40, "Clamped to the full width: an edge tab has no trailing inset")
    }

    @MainActor
    @Test func downSequencerSkipsReturnToLiveAfterSessionEnds() async {
        var live = true
        var returnToLiveCalls = 0
        let outcome = await MessageJumpDownSequencer.run(
            jumpNewer: {
                live = false
                return .reachedEnd
            },
            returnToLive: {
                returnToLiveCalls += 1
                return .reachedEnd
            },
            isLive: { live })
        #expect(outcome == nil)
        #expect(returnToLiveCalls == 0)
    }

    @MainActor
    @Test func downSequencerReturnsFoundWithoutCallingReturnToLive() async {
        var live = true
        var returnToLiveCalls = 0
        let outcome = await MessageJumpDownSequencer.run(
            jumpNewer: { .found },
            returnToLive: {
                returnToLiveCalls += 1
                return .reachedEnd
            },
            isLive: { live })
        #expect(outcome == .found)
        #expect(returnToLiveCalls == 0)
    }

    @MainActor
    @Test func grokProfileWidensPromptRecognitionWithoutChangingOtherAgents() {
        let grok = AgentMessageJumpProfile.forAgentKind("grok")
        #expect(grok.policy == .stickyPromptOvershoot)
        #expect(grok.maximumPromptIndent == 5)
        let grokWiring = AgentMessageJumpWiring(profile: grok)
        #expect(
            grokWiring.messageIndex.visibleMessageKeys("     ❯ /handoff")
                == ["line:/handoff"])

        for kind in ["claude", "codex", "cursor", "", "unknown"] {
            let profile = AgentMessageJumpProfile.forAgentKind(kind)
            #expect(profile.policy == .neighborAppearance)
            #expect(
                profile.maximumPromptIndent
                    == AttachUserMessageIndex.maximumPromptIndent)
            let wiring = AgentMessageJumpWiring(profile: profile)
            #expect(wiring.messageIndex.visibleMessageKeys("     ❯ /handoff").isEmpty)
        }
    }

    /// Antigravity CLI draws a past prompt flush left behind `> `, which the
    /// default profile reads; its empty box's `>` names nothing.
    @MainActor
    @Test func theDefaultProfileReadsAntigravityCLIPrompts() throws {
        let profile = AgentMessageJumpProfile.forAgentKind("agy")
        #expect(profile.policy == .neighborAppearance)
        let wiring = AgentMessageJumpWiring(profile: profile)
        let frame = try ScreenFixture.screen("agy-36-done-final-120x40").rows.map(\.text)
            .joined(separator: "\n")

        #expect(
            wiring.messageIndex.visibleMessageKeys(frame) == [
                "line:Reply with only the word pear.", "line:Also reply with the word kiwi",
                "line:Run exactly this shell command in the current directory: sleep 40; echo probe-done . Then reply with its output only.",
            ])
    }

    @MainActor
    @Test func wiringForwardsTheJumpPolicy() {
        let sticky = AgentMessageJumpWiring(policy: .stickyPromptOvershoot)
        #expect(sticky.controller.policy == .stickyPromptOvershoot)
        let standard = AgentMessageJumpWiring()
        #expect(standard.controller.policy == .neighborAppearance)
    }

    @MainActor
    @Test func runJumpAbandonsBodyWhenResetBeforeStart() async {
        let wiring = AgentMessageJumpWiring()
        var bodyEntered = false
        wiring.runJump(.older) { _ in
            bodyEntered = true
        }
        // Reconnect wins the main-actor queue before the Task body runs.
        wiring.resetSession()
        await Task.yield()
        await Task.yield()
        #expect(!bodyEntered)
        #expect(wiring.jumpInvocationCount == 0)
        #expect(!wiring.isJumpRunning)
    }

    @MainActor
    @Test func runJumpInvokesBodyWhenSessionStaysLive() async {
        let wiring = AgentMessageJumpWiring()
        var bodyEntered = false
        wiring.runJump(.newer) { session in
            #expect(wiring.isLive(session))
            #expect(wiring.isJumpRunning)
            #expect(wiring.runningDirection == .newer)
            bodyEntered = true
        }
        await Task.yield()
        await Task.yield()
        #expect(bodyEntered)
        #expect(wiring.jumpInvocationCount == 1)
        #expect(!wiring.isJumpRunning)
        #expect(wiring.runningDirection == nil)
    }

    @MainActor
    @Test func resetSessionAdvancesGeneration() {
        let wiring = AgentMessageJumpWiring()
        let first = wiring.liveGeneration
        wiring.resetSession()
        #expect(!wiring.isLive(first))
        #expect(wiring.isLive(wiring.liveGeneration))
    }

    @Test func availabilityDisabledMeansOverlayShouldNotHitTest() {
        let walking = MessageJumpControlAvailability.evaluate(
            isAlternateScreen: true,
            canScrollRemoteContent: true,
            runningDirection: .older)
        #expect(walking.isVisible)
        // AgentTerminalView gates `.allowsHitTesting` on isEnabled, not
        // isVisible — this pins the policy the overlay relies on.
        #expect(walking.isEnabled == false)
    }
}
