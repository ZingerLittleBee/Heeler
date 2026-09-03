import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Host that reports a stable intrinsic size so
/// `MessageJumpChromeContainer.layoutSubviews` does not collapse to zero.
private final class MessageJumpSizedHost: UIView {
    var fixedSize: CGSize = CGSize(width: 44, height: 72)

    override var intrinsicContentSize: CGSize { fixedSize }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(fixedSize.width, size.width > 0 ? size.width : fixedSize.width),
            height: fixedSize.height)
    }
}

struct MessageJumpControlTests {
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

    /// Reaching an end is conveyed by the direction's button disappearing,
    /// not by a caption. Only a walk that ran out of budget says anything.
    @Test func noticeCopySpeaksOnlyForAnExhaustedWalk() {
        #expect(MessageJumpNotice.text(for: .found) == nil)
        #expect(MessageJumpNotice.text(for: .cancelled) == nil)
        #expect(MessageJumpNotice.text(for: .reachedEnd) == nil)
        #expect(MessageJumpNotice.text(for: .exhausted) == "Couldn't find the message")
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
        #expect(narrowFrame?.width == 30)
    }

    @MainActor
    @Test func shortTerminalContainerHidesChromeThatCannotFit() throws {
        let container = MessageJumpChromeContainer(
            frame: CGRect(x: 0, y: 0, width: 390, height: 80))
        let host = MessageJumpSizedHost()
        host.fixedSize = CGSize(width: 44, height: 72)
        container.embed(host)
        container.layoutIfNeeded()
        #expect(host.isHidden)
        #expect(container.hostedFrame == nil)

        container.frame = CGRect(x: 0, y: 0, width: 390, height: 160)
        container.layoutIfNeeded()
        #expect(!host.isHidden)
        let frame = try #require(container.hostedFrame)
        #expect(
            MessageJumpPlacement.sitsAboveBottomBand(
                terminalHeight: 160,
                controlHeight: frame.height,
                bottomInset: MessageJumpPlacement.bottomInset(terminalHeight: 160)))
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

    /// The wiring's Down press folds movement from *both* legs into reach:
    /// a newer walk that finds nothing but does move, followed by a return
    /// to live, still counts as having moved. `refs #268`.
    @MainActor
    @Test func wiringReachFollowsJumpOutcomes() async {
        let wiring = AgentMessageJumpWiring()
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        wiring.scrollControl.terminal = terminal
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(wiring.reach == MessageJumpReach())

        // Nothing ever repaints: an older walk reaches the end without moving.
        let session = wiring.liveGeneration
        let older = await wiring.jumpOlder(in: session)
        #expect(older == .reachedEnd)
        #expect(!wiring.reach.canJumpOlder)
        #expect(!wiring.reach.canJumpNewer)

        wiring.resetSession()
        #expect(wiring.reach == MessageJumpReach())
    }

    @MainActor
    @Test func wiringLearnsDisplacementFromTouchScrolls() {
        let wiring = AgentMessageJumpWiring()
        let terminal = TerminalScreenView.makeConfiguredTerminal(onScroll: { _, _ in })
        wiring.scrollControl.terminal = terminal

        // Primary screen: local scrollback, not a remote position change.
        _ = terminal.scrollTouch(translationY: 40)
        #expect(!wiring.reach.canJumpNewer)

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        _ = terminal.scrollTouch(translationY: 40)
        #expect(wiring.reach.canJumpNewer)
    }

    @MainActor
    @Test func resetSessionAdvancesGeneration() {
        let wiring = AgentMessageJumpWiring()
        let first = wiring.liveGeneration
        wiring.resetSession()
        #expect(!wiring.isLive(first))
        #expect(wiring.isLive(wiring.liveGeneration))
    }

    @MainActor
    @Test func chromeContainerPassesThroughNonInteractiveAndDisabledHits() {
        let container = MessageJumpChromeContainer(
            frame: CGRect(x: 0, y: 0, width: 390, height: 720))
        let host = MessageJumpSizedHost()
        host.fixedSize = CGSize(width: 44, height: 80)
        let chrome = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 80))
        chrome.isUserInteractionEnabled = true
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 36)
        chrome.addSubview(button)
        host.addSubview(chrome)
        // Size the host so layoutSubviews does not collapse it.
        host.frame = CGRect(x: 0, y: 0, width: 44, height: 80)
        container.embed(host)
        container.layoutIfNeeded()

        #expect(!host.isHidden)
        #expect(container.hostedFrame != nil)

        let buttonPoint = container.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            from: button)
        #expect(container.hitTest(buttonPoint, with: nil) === button)

        let paddingPoint = container.convert(CGPoint(x: 22, y: 60), from: chrome)
        #expect(container.hitTest(paddingPoint, with: nil) == nil)
        #expect(container.hitTest(CGPoint(x: 12, y: 12), with: nil) == nil)

        #expect(
            MessageJumpChromeContainer.isInteractive(button, stoppingAt: host))
        #expect(
            !MessageJumpChromeContainer.isInteractive(chrome, stoppingAt: host))

        // Disabled controls must not eat terminal drags.
        button.isEnabled = false
        #expect(container.hitTest(buttonPoint, with: nil) == nil)
        #expect(
            !MessageJumpChromeContainer.isInteractive(button, stoppingAt: host))
    }

    /// SwiftUI does not back a `Button` with its own `UIView`; a hosting view
    /// answers for its whole interactive area and its gesture recognizers run
    /// the action. Rejecting a hit that is the hosted root left the buttons
    /// reachable by VoiceOver but by no actual touch. `refs #268`.
    @Test func aGestureBackedHostedRootIsInteractive() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 80))

        // An inert container still passes terminal drags through.
        #expect(!MessageJumpChromeContainer.isInteractive(host, stoppingAt: host))

        host.addGestureRecognizer(UITapGestureRecognizer())
        #expect(MessageJumpChromeContainer.isInteractive(host, stoppingAt: host))
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

@MainActor
struct TerminalScrollControlTests {
    @Test func scrollRowsEmitsRemoteWheelOnAlternateScreenWithMouseTracking() {
        var scrolledSequence = Data()
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { sequence, rows in
                scrolledSequence = sequence
                scrolledRows = rows
            })
        let control = TerminalScrollControl()
        control.terminal = terminal

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(control.isAlternateScreen)

        control.scrollRows(towardOlderContent: true, rows: 6)
        #expect(scrolledSequence == Data("\u{1B}[<64;40;12M".utf8))
        #expect(scrolledRows == 6)

        scrolledSequence = Data()
        scrolledRows = 0
        control.scrollRows(towardOlderContent: false, rows: 3)
        #expect(scrolledSequence == Data("\u{1B}[<65;40;12M".utf8))
        #expect(scrolledRows == 3)
    }

    @Test func scrollRowsEmitsCursorKeysOnAlternateScreenWithoutMouseTracking() {
        var scrolledSequence = Data()
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { sequence, rows in
                scrolledSequence = sequence
                scrolledRows = rows
            })
        let control = TerminalScrollControl()
        control.terminal = terminal

        terminal.receive(Data("\u{1B}[?1049h".utf8))
        control.scrollRows(towardOlderContent: true, rows: 2)
        #expect(scrolledSequence == Data([0x1B, 0x5B, 0x41]))
        #expect(scrolledRows == 2)

        scrolledSequence = Data()
        control.scrollRows(towardOlderContent: false, rows: 2)
        #expect(scrolledSequence == Data([0x1B, 0x5B, 0x42]))
    }

    @Test func scrollRowsTakesLocalBranchOnPrimaryScreen() {
        var scrollCalls = 0
        var bindingActions: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { _, _ in scrollCalls += 1 })
        terminal.didPerformBindingAction = { bindingActions.append($0) }
        let control = TerminalScrollControl()
        control.terminal = terminal

        #expect(!control.isAlternateScreen)
        control.scrollRows(towardOlderContent: true, rows: 4)
        #expect(scrollCalls == 0)
        #expect(bindingActions == ["scroll_page_lines:-4"])

        bindingActions.removeAll()
        control.scrollRows(towardOlderContent: false, rows: 2)
        #expect(bindingActions == ["scroll_page_lines:2"])
    }

    @Test func scrollRowsLeavesTheTouchAccumulatorAlone() {
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { _, rows in scrolledRows += rows })
        let control = TerminalScrollControl()
        control.terminal = terminal
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))

        #expect(terminal.scrollTouch(translationY: 8) == 0)
        control.scrollRows(towardOlderContent: true, rows: 2)
        #expect(scrolledRows == 2)
        scrolledRows = 0
        #expect(terminal.scrollTouch(translationY: 8) == 1)
        #expect(scrolledRows == 1)
    }

    @Test func isAlternateScreenSyncsFromTheSurfaceAndClearsOnRelease() {
        let control = TerminalScrollControl()
        #expect(!control.isAlternateScreen)

        let terminal = TerminalScreenView.makeConfiguredTerminal()
        control.terminal = terminal
        #expect(!control.isAlternateScreen)

        terminal.receive(Data("\u{1B}[?1049h".utf8))
        #expect(control.isAlternateScreen)

        terminal.receive(Data("\u{1B}[?1049l".utf8))
        #expect(!control.isAlternateScreen)

        terminal.receive(Data("\u{1B}[?1049h".utf8))
        #expect(control.isAlternateScreen)
        control.terminal = nil
        #expect(!control.isAlternateScreen)
    }
}

@MainActor
struct MessageJumpAgentTerminalWiringTests {
    @Test func agentTerminalViewportFeedsTheJumpController() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            throw TransportError.cancelled
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode()
        defer { cleanup() }
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                inputMode: inputMode,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.receive(
            Data("\u{001B}[2J\u{001B}[Hhttps://msgnav.example/viewport\n".utf8))
        terminal.layoutIfNeeded()

        try #require(await Self.eventually {
            interactions.messageJumpViewportFrames.contains {
                $0.contains("https://msgnav.example/viewport")
            }
                && interactions.lastMessageJumpViewportFrame?
                .contains("https://msgnav.example/viewport") == true
        })
    }

    @Test func interactionProbeJumpActionsAreConnectedOnAppear() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            throw TransportError.cancelled
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode()
        defer { cleanup() }
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                inputMode: inputMode,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { interactions.isConnected })

        // Probe closures are wired on appear. Without alternate-screen /
        // enabled chrome the actions no-op at the availability guard — the
        // probe still reports the closures were reached.
        #expect(interactions.jumpOlderMessage())
        #expect(interactions.jumpNewerMessage())
    }

    private static func makeInputMode(
        initial: AgentInputMode = .composer
    ) throws -> (AgentInputModeSettings, () -> Void) {
        let suiteName = "msgnav-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AgentInputModeSettings(defaults: defaults)
        if initial != .composer {
            settings.select(initial)
        }
        return (settings, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private static func makeLiveAttach(
        transport: ScriptedTransport,
        composer: AgentComposerStore
    ) async throws -> AgentAttachStore {
        let owner = AgentAttachStore(
            target: "w1:p1",
            paneTitle: "Claude",
            transportGeneration: 1,
            isOnStage: { true },
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            },
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled },
            composer: composer,
            closePane: {})
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 1
        })
        #expect(await transport.emitAttachOutput(Data("live".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })
        return owner
    }

    private static func makeDetailView(
        attachStore: AgentAttachStore,
        composer: AgentComposerStore,
        inputMode: AgentInputModeSettings,
        interactionProbe: AgentTerminalInteractionProbe
    ) -> AgentTerminalView {
        let defaults = UserDefaults(suiteName: "msgnav-detail-\(UUID())") ?? .standard
        let console = ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "fixture") },
                reconnectPolicy: .default,
                keepalive: .default)
        }
        let terminal = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults))
        return AgentTerminalView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_w1:p1", kind: "claude", title: "",
                    status: .idle, workspaceID: "w", tabID: "w:t", paneID: "w1:p1",
                    cwd: "/work", revision: 1, name: nil),
                workspaceLabel: nil,
                repositoryCheckout: nil),
            console: console,
            terminal: terminal,
            inputMode: inputMode,
            hosts: [],
            activity: AppActivityCoordinator(),
            keyboardHandoff: TerminalKeyboardHandoff(),
            keyboardInset: TerminalKeyboardInset(),
            isOnStage: { true },
            onSwitch: { _ in },
            onClosed: {},
            composer: composer,
            attachStore: attachStore,
            interactionProbe: interactionProbe)
    }

    private static func terminals(in root: UIView) -> [HeelerTerminalView] {
        var found: [HeelerTerminalView] = []
        func walk(_ view: UIView) {
            if let terminal = view as? HeelerTerminalView {
                found.append(terminal)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private static func eventually(
        timeout: Duration = .seconds(5),
        _ condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
