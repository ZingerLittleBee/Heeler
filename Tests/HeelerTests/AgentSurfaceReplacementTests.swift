import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// What happens when SwiftUI replaces a terminal surface (#152).
///
/// Whole-screen replacement is the one path #143 could not disprove:
/// `AgentDetailView` holds `@State private var attach`, so an Agent switch
/// releases one store and constructs another, in an order that is SwiftUI's
/// and unspecified. These tests drive that replacement through the real view
/// and observe what the feed does across it.
///
/// A hosted `ConsoleView` was tried first and abandoned: a hosted
/// `NavigationSplitView` builds its columns, separators and navigation bar but
/// never the SwiftUI content inside them, so nothing below it can be observed
/// (measured: 72 views, all chrome, identical with and without a selection).
/// `AgentDetailView` is not subject to that — it is a plain view and its
/// terminal surface really is built.
@MainActor
@Suite("Agent surface replacement")
struct AgentSurfaceReplacementTests {
    /// A replacement surface must take over the feed, or output goes to a view
    /// the user cannot see.
    ///
    /// The released predecessor plus the new surface's parsed viewport make the
    /// replacement conclusive without inventing a renderer acknowledgement.
    @Test func aReplacementSurfaceTakesOverTheFeed() async throws {
        struct Harness: View {
            let feed: TerminalByteFeed
            let surface: Int

            var body: some View {
                TerminalScreenView(feed: feed)
                    .id(surface)
            }
        }

        let feed = TerminalByteFeed()
        let controller = UIHostingController(rootView: Harness(feed: feed, surface: 1))
        // This seam needs a UIKit hierarchy, not a connected app scene. A
        // scene is absent in some headless test-host launches, which made the
        // otherwise deterministic loop fail before it reached AgentDetailView.
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        // Deliberately not retained: the predecessor has to be free to go away,
        // or a stale sink would still look live.
        weak var predecessor = Self.terminals(in: controller.view).first
        #expect(predecessor != nil, "the first surface should exist")
        feed.write(Data("first".utf8))

        controller.rootView = Harness(feed: feed, surface: 2)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(100))

        let replacement = try #require(
            Self.terminals(in: controller.view).first,
            "SwiftUI should have built a replacement surface")
        #expect(predecessor == nil, "the replaced surface should have gone away")
        feed.write(Data("second".utf8))
        try #require(await Self.eventually {
            replacement.terminalSession.readViewportText()?.contains("second") == true
        }, "output after a replacement must reach the replacement's terminal session")
        #expect(Self.terminals(in: controller.view).count == 1)
        _ = replacement
    }

    /// An Agent switch must build a surface for the store it just constructed.
    ///
    /// This is the regression #143's `TerminalSurfaceID` guards: an
    /// address-derived id can repeat across a release-then-construct, and a
    /// repeated id is one SwiftUI reads as "same surface, keep it" — leaving
    /// the new store's terminal with no surface at all. Measured on this tree,
    /// 200 stores built and dropped in a row produced only 2 distinct
    /// `ObjectIdentifier`s, so the collision is likely rather than exotic.
    ///
    /// It runs many rounds for that reason: one switch may or may not reuse an
    /// address, and the defect only shows on a round that does.
    ///
    /// Note what this does **not** add, both halves measured rather than
    /// argued. Reverting `AgentAttachStore.terminalID` to
    /// `ObjectIdentifier(terminal)` turns the `AgentAttachStoreTests` suite red
    /// on its own (36 tests, 2 failures, one of them reproducing the 200-to-2
    /// address collision directly) and leaves **this** test green. So it
    /// contributes no mutation coverage for that revert.
    ///
    /// What it does contribute is the end-to-end path: it is the only test in
    /// the suite that drives a real SwiftUI screen replacement, so it would
    /// catch a regression that stopped building a surface for the new store by
    /// some route the store-level tests do not model. That makes it a
    /// characterisation of what SwiftUI does today, not a guarantee it will
    /// keep doing it — if a future SwiftUI stops replacing the surface here,
    /// this test reports that change rather than a defect.
    @Test(.timeLimit(.minutes(1)))
    func anAgentSwitchBuildsASurfaceForTheNewStore() async throws {
        struct Harness: View {
            let agent: ConsoleAgent
            let make: (ConsoleAgent) -> AgentDetailView

            var body: some View {
                // Mirrors what `ConsoleView` puts on its detail column: the
                // Agent's own id, which is what makes a switch a replacement
                // rather than an update.
                make(agent)
                    .id(agent.id)
            }
        }

        let host = UUID()
        let agents = (1...12).map { Self.makeAgent(pane: "w1:p\($0)", host: host) }
        let make = Self.detailViewFactory()
        let controller = UIHostingController(
            rootView: Harness(agent: agents[0], make: make))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        var surfaces: [ObjectIdentifier] = []
        var roundsWithoutASurface: [Int] = []
        for round in agents.indices {
            controller.rootView = Harness(agent: agents[round], make: make)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(50))

            guard let terminal = Self.terminals(in: controller.view).first else {
                roundsWithoutASurface.append(round)
                continue
            }
            surfaces.append(ObjectIdentifier(terminal))
        }

        #expect(
            roundsWithoutASurface.isEmpty,
            "an Agent switch left the screen with no terminal surface on rounds \(roundsWithoutASurface)")
        // Every switch is a fresh screen, so no two consecutive rounds may be
        // looking at the same surface object.
        let repeats = zip(surfaces, surfaces.dropFirst()).filter { $0 == $1 }.count
        #expect(
            repeats == 0,
            "\(repeats) of \(surfaces.count - 1) switches reused the previous surface")
    }

    /// The production call-site seam for #141. Recovery must replace every
    /// terminal-owned object while leaving the surrounding Attach interaction
    /// intact: links, an image result, and a Paste awaiting confirmation all
    /// belong to this Attach until the user actually leaves it.
    @Test func aPossibleSuspensionRebuildsTheTerminalAndPreservesAttachState() async throws {
        var now = ContinuousClock.now
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(20),
            granter: SurfaceTestBackgroundGranter(),
            now: { now })
        let transport = ScriptedTransport()
        let owner = Self.makeAttachStore(transport: transport)
        let agent = Self.makeAgent(pane: "w1:p1")
        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: agent,
                activity: activity,
                attachStore: owner))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        controller.view.layoutIfNeeded()

        try #require(await Self.eventually {
            await transport.attachRequests.count == 1
        }, "the first PTY Attach should open")
        #expect(await transport.emitAttachOutput(Data("opening".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == .live
        }, "the first Attach should become live")
        let firstTerminalID = owner.terminalID
        let firstFeed = owner.terminalFeed
        weak var predecessor: HeelerTerminalView?
        let firstSurfaceID: ObjectIdentifier
        do {
            let firstSurface = try #require(Self.terminals(in: controller.view).first)
            predecessor = firstSurface
            firstSurfaceID = ObjectIdentifier(firstSurface)
        }

        owner.viewportTextDidChange("https://before.example/recovery")
        owner.selectImage(DataImageSelection(data: Data([0x01])))
        try #require(await Self.eventually {
            owner.imageState.isFailed
        }, "the image result should surface before recovery")
        let imageResult = owner.imageState
        owner.requestPaste("git status\ngit diff", bracketedPaste: true)
        let pendingPaste = try #require(owner.pendingPaste)

        activity.didEnterBackground()
        now = now.advanced(by: .seconds(5))
        activity.didBecomeActive()
        try await Task.sleep(for: .milliseconds(100))

        #expect(
            await transport.attachRequests.count == 1,
            "a short bounce must not open another PTY Attach")
        #expect(
            owner.terminalStatus == .live,
            "a short bounce must not show Connecting")
        #expect(
            Self.terminals(in: controller.view).first.map(ObjectIdentifier.init) == firstSurfaceID,
            "a short bounce must keep the terminal surface")
        #expect(owner.terminalID == firstTerminalID)
        #expect(owner.terminalFeed === firstFeed)

        activity.didEnterBackground()
        now = now.advanced(by: .seconds(20))
        activity.didBecomeActive()

        let didReplaceTerminal = try await Self.eventually {
            owner.terminalID != firstTerminalID
        }
        let didExecuteAnotherAttach = try await Self.eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return await transport.attachRequests.count == 2
        }
        try #require(didReplaceTerminal, "recovery should replace the terminal pipeline")
        try #require(didExecuteAnotherAttach, "the replacement should execute a new PTY Attach")
        try #require(await Self.eventually {
            predecessor == nil
        }, "the old terminal surface should detach")
        let replacement = try #require(
            Self.terminals(in: controller.view).first,
            "recovery should create and attach a new terminal surface")

        #expect(ObjectIdentifier(replacement) != firstSurfaceID)
        #expect(owner.terminalFeed !== firstFeed, "the replacement needs a new byte feed")
        #expect(owner.attachLinks.map(\.target) == ["https://before.example/recovery"])
        #expect(owner.imageState == imageResult)
        #expect(owner.pendingPaste == pendingPaste)

        #expect(await transport.emitAttachOutput(Data("recovered-frame".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == .live
                && replacement.terminalSession.readViewportText()?.contains("recovered-frame") == true
        }, "new output should reach the new surface and leave a visible live terminal")

        await owner.leave().value
        window.isHidden = true
        window.rootViewController = nil
        await Task.yield()
    }

    @Test func recoveryDiagnosticNamesEveryLayerWithoutInventingPresentationProof() {
        let diagnostic = AttachRecoveryDiagnostic(absence: .seconds(180), sshGeneration: 7)

        #expect(
            diagnostic.lines(attachStatus: .connecting, terminalSurfaceAttached: true) == [
                "Away: 180 s",
                "SSH generation: 7",
                "Attach session/channel: new PTY Attach opening; first output unobserved",
                "Terminal surface: new surface attached",
                "Render loop: unobserved (no presentation acknowledgement)",
            ])
    }

    // MARK: Fixtures

    static func terminals(in root: UIView) -> [HeelerTerminalView] {
        var found: [HeelerTerminalView] = []
        func walk(_ view: UIView) {
            if let terminal = view as? HeelerTerminalView { found.append(terminal) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    /// A SwiftUI/UIKit hierarchy is sufficient for these replacement tests.
    /// Requiring `UIApplication.connectedScenes` made the test precondition
    /// depend on how the headless runner launched its host, before any product
    /// code ran.
    static func makeLocalTestWindow(
        frame: CGRect,
        rootViewController: UIViewController
    ) -> UIWindow {
        let window = UIWindow(frame: frame)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        return window
    }

    static func makeAgent(pane: String, host: UUID = UUID()) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host,
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_\(pane)", kind: "claude", title: "",
                status: .idle, workspaceID: "w", tabID: "w:t", paneID: pane,
                cwd: "/work", revision: 1, name: nil),
            workspaceLabel: nil,
            repoName: nil,
            lastOutputSnippet: nil)
    }

    /// Mirrors what `ConsoleView` hands its detail column rather than importing
    /// a fixture: `DemoScreenshotFixture` is
    /// `#if DEBUG && targetEnvironment(simulator)`, so depending on it would bar
    /// these tests from ever running on a device.
    ///
    /// The stores are built once and shared across switches because that is
    /// what the Console does — only the Agent changes.
    static func detailViewFactory() -> (ConsoleAgent) -> AgentDetailView {
        let defaults = UserDefaults(suiteName: "agent-surface-\(UUID())") ?? .standard
        let console = ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    throw TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
                },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: .default)
        }
        let terminal = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults))
        let handoff = TerminalKeyboardHandoff()
        let inset = TerminalKeyboardInset()
        let activity = AppActivityCoordinator()
        return { agent in
            AgentDetailView(
                agent: agent,
                console: console,
                terminal: terminal,
                hosts: [],
                activity: activity,
                keyboardHandoff: handoff,
                keyboardInset: inset,
                isOnStage: { true },
                onSwitch: { _ in },
                onClosed: {})
        }
    }

    private static func makeDetailView(
        agent: ConsoleAgent,
        activity: AppActivityCoordinator,
        attachStore: AgentAttachStore
    ) -> AgentDetailView {
        let defaults = UserDefaults(suiteName: "attach-recovery-\(UUID())") ?? .standard
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
        return AgentDetailView(
            agent: agent,
            console: console,
            terminal: terminal,
            hosts: [],
            activity: activity,
            keyboardHandoff: TerminalKeyboardHandoff(),
            keyboardInset: TerminalKeyboardInset(),
            isOnStage: { true },
            onSwitch: { _ in },
            onClosed: {},
            attachStore: attachStore)
    }

    private static func makeAttachStore(transport: ScriptedTransport) -> AgentAttachStore {
        AgentAttachStore(
            target: "w1:p1",
            paneTitle: "pane",
            transportGeneration: 1,
            isOnStage: { true },
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                do {
                    try await handler.run(session)
                    await session.end()
                } catch {
                    await session.end()
                    throw error
                }
            },
            stageImage: { _, _ in throw TransportError.cancelled },
            closePane: {})
    }

    private static func eventually(
        timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

@MainActor
private final class SurfaceTestBackgroundGranter: BackgroundExecutionGranting {
    private var nextRawValue = 1

    func begin(
        onExpiration _: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        defer { nextRawValue += 1 }
        return BackgroundExecutionToken(rawValue: nextRawValue)
    }

    func end(_: BackgroundExecutionToken) {}
}
