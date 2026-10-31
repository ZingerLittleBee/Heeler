import Foundation
import SwiftUI
import Testing

@testable import Heeler

/// A core Host's terminals from the store down: the real Console, Host session
/// and link, with the SSH connection and the core scripted.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreTerminalStoreTests {
    private final class Sink: TerminalByteSink {
        var received = Data()
        func receive(_ data: Data) { received.append(data) }
    }

    /// The Console builds its Host session; this keeps hold of it.
    private final class SessionBox: @unchecked Sendable {
        var session: HerdrCoreHostSession?
    }

    @MainActor
    private struct Fixture {
        let scripted: ScriptedCoreHost
        private let box = SessionBox()
        private let directory = AgentSceneDirectory()
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        let console: ConsoleStore

        init(terminals: [JSONValue] = []) async throws {
            let scripted = ScriptedCoreHost(channel: .core(.init(id: "c1", terminals: terminals)))
            self.scripted = scripted
            let box = box
            console = ConsoleStore(
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in
                    let session = HerdrCoreHostSession(
                        connect: {
                            await scripted.setConnected(true)
                            return scripted.transport()
                        },
                        keepalive: nil)
                    box.session = session
                    return session
                },
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-terminals-\(UUID().uuidString)") ?? .standard))
            console.setHosts([host])
            await console.resume()
            try await until("the first snapshot") { [console, host] in
                !console.hostsAwaitingSnapshot.contains(host.id)
            }
        }

        var runner: TerminalSessionRunner { console.terminalRunner(for: host.id) }

        func store(
            _ address: String = "t1", viewer: TerminalViewerRole = .interactive, isViewed: Bool = true
        ) -> AttachTerminalStore {
            AttachTerminalStore(
                target: .terminal(address), viewer: viewer, isViewed: isViewed, runTerminal: runner)
        }

        /// The store's attach, once the core has answered it.
        func opened(
            _ store: AttachTerminalStore, count: Int = 1
        ) async throws -> (channel: UInt32, params: JSONValue, socket: FakeCoreSocket) {
            store.viewDidResize(cols: 80, rows: 24)
            await scripted.waitForMethod("terminal.attach", count: count)
            let attach = try #require(await scripted.attaches.last)
            return attach
        }

        func deliverOutput(_ text: String, on attach: (channel: UInt32, params: JSONValue, socket: FakeCoreSocket))
            async throws
        {
            try await attach.socket.deliver(
                HerdrCoreFrame(channel: attach.channel, kind: .data, payload: Data(text.utf8)))
        }

        /// A round trip on the link, so what it queued before has left.
        func settle() async throws {
            let session = try #require(box.session)
            for _ in 0..<2 {
                _ = try await session.withTransport { try await $0.serverStatus() }
            }
        }

        /// A window showing `agent`'s detail, built as the Console builds it.
        /// `sceneID` puts it under a scene root, as a real window is.
        func showDetail(of agent: ConsoleAgent, sceneID: UUID? = nil) async throws -> CoreDetailWindow {
            let suite = "core-detail-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let selection = HostedDetailSelection()
            let changes = AgentChangesPresentation {
                ChangesStore(directory: { "/work/app" }) { _ in throw ChangesReadError.unavailable }
            }
            let console = console
            let activity = AppActivityCoordinator()
            let handoff = TerminalKeyboardHandoff()
            let inset = TerminalKeyboardInset()
            let routing = sceneID.map { AgentSceneRouting(directory: directory, sceneID: $0) }
            let controller = UIHostingController(
                rootView: HostedCoreDetail(selection: selection, routing: routing) {
                    AgentDetailView(
                        agent: agent,
                        console: console,
                        terminal: TerminalSettings(
                            themes: TerminalThemeSettings(defaults: defaults),
                            zoom: TerminalZoomSettings(defaults: defaults),
                            fonts: TerminalFontSettings(defaults: defaults),
                            snippets: SnippetStore(defaults: defaults)),
                        inputMode: AgentInputModeSettings(defaults: defaults),
                        detailSurface: AgentDetailSurfaceSettings(defaults: defaults),
                        hosts: [],
                        activity: activity,
                        keyboardHandoff: handoff,
                        keyboardInset: inset,
                        stage: AgentDetailStage(
                            isVisible: { [selection] in selection.showsDetail },
                            terminalAccess: { .holds }),
                        onSwitch: { _ in },
                        onClosed: {},
                        changesPresentation: changes)
                })
            let window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
            return CoreDetailWindow(selection: selection, changes: changes, window: window)
        }

        /// The `count`th attach on the Host, once `detail` has asked for it.
        func waitForAttach(_ count: Int, laying detail: CoreDetailWindow) async throws
            -> (channel: UInt32, params: JSONValue, socket: FakeCoreSocket)
        {
            try await HerdrCoreTerminalStoreTests.until("attach \(count)") {
                detail.layOut()
                return await scripted.attaches.count >= count
            }
            return try #require(await scripted.attaches.dropFirst(count - 1).first)
        }

        func finish() async {
            await console.terminalConnections.suspend()
            await console.agentTerminals.suspend()
            console.setHosts([])
        }
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

    private static let facts = TerminalDisplayFacts(
        foreground: "#ffffff", background: "#000000", cursor: "#ff0000", cell: .init(width: 10, height: 20))

    // MARK: Credit

    @Test func bytesWaitingForASurfaceHoldTheirCreditUntilItTakesThem() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        try await fixture.deliverOutput("opening", on: attach)
        try await Self.until("the first output") { store.status == .live }
        try await fixture.settle()
        #expect(await attach.socket.creditTotal(channel: attach.channel) == 0)

        let sink = Sink()
        store.feed.attach(sink)
        #expect(sink.received == Data("opening".utf8))
        await attach.socket.waitForCredit(channel: attach.channel, total: 7)
        await store.stop()
        await fixture.finish()
    }

    @Test func bytesASurfaceTakesReturnTheirCreditAndAGoneSurfaceHoldsNothingUp() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        var sink: Sink? = Sink()
        if let sink { store.feed.attach(sink) }
        try await fixture.deliverOutput("seen", on: attach)
        await attach.socket.waitForCredit(channel: attach.channel, total: 4)
        #expect(sink?.received == Data("seen".utf8))

        sink = nil
        try await fixture.deliverOutput("unseen", on: attach)
        await attach.socket.waitForCredit(channel: attach.channel, total: 10)
        await store.stop()
        await fixture.finish()
    }

    // MARK: Viewer role, focus and facts

    @Test func aViewedAttachOpensInteractiveAndReportsFocusAndFacts() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        store.feed.updateDisplayFacts { $0 = Self.facts }
        let attach = try await fixture.opened(store)
        #expect(attach.params["resumed"] == nil)
        #expect(attach.params["observe"] == nil)
        #expect(attach.params["takeover"] == nil)
        #expect(attach.params["display"]?["bg"] == .string("#000000"))
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
        #expect(
            await attach.socket.frames(channel: attach.channel, kind: .focus).map(\.payload) == [Data([1])])
        await store.stop()
        await fixture.finish()
    }

    @Test func aHiddenAttachReportsNothingUntilItIsViewedAndOneEdgeWhenItLeaves() async throws {
        let fixture = try await Fixture()
        let store = fixture.store(isViewed: false)
        store.feed.updateDisplayFacts { $0 = Self.facts }
        let attach = try await fixture.opened(store)
        #expect(attach.params["resumed"] == .bool(true))
        #expect(attach.params["display"] == nil)
        store.feed.updateDisplayFacts { $0.cell = .init(width: 12, height: 24) }
        try await fixture.settle()
        #expect(await attach.socket.frames(channel: attach.channel, kind: .focus).isEmpty)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .facts).isEmpty)

        store.setViewed(true)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
        #expect(
            await attach.socket.frames(channel: attach.channel, kind: .focus).map(\.payload) == [Data([1])])

        store.setViewed(false)
        try await Self.until("focus lost") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).map(\.payload) == [Data([1]), Data([0])]
        }
        store.feed.updateDisplayFacts { $0.cell = .init(width: 14, height: 28) }
        try await fixture.settle()
        #expect(await attach.socket.frames(channel: attach.channel, kind: .facts).count == 1)
        await store.stop()
        await fixture.finish()
    }

    @Test func aViewedAttachReportsItsFactsChangingAndEveryResize() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        store.feed.updateDisplayFacts { $0 = Self.facts }
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
        store.viewDidResize(cols: 100, rows: 30)
        store.viewDidResize(cols: 80, rows: 24)
        try await Self.until("two resizes") {
            await attach.socket.frames(channel: attach.channel, kind: .resize).count == 2
        }
        #expect(
            await attach.socket.frames(channel: attach.channel, kind: .resize).map(\.payload)
                == [Data([100, 0, 30, 0]), Data([80, 0, 24, 0])])
        await store.stop()
        await fixture.finish()
    }

    @Test func comingBackToTheForegroundReportsFocusAndNeverNudgesTheSize() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the first output") { store.status == .live }
        store.didBecomeActive()
        try await Self.until("a second focus") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).count == 2
        }
        #expect(await attach.socket.frames(channel: attach.channel, kind: .resize).isEmpty)
        await store.stop()
        await fixture.finish()
    }

    @Test func typedBytesReachTheAttachUnchanged() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the first output") { store.status == .live }
        store.send(Data([0x1C]))
        let typed = await attach.socket.waitForFrame(channel: attach.channel, kind: .data)
        #expect(typed.payload == Data([0x1C]))
        await store.stop()
        await fixture.finish()
    }

    @Test func anAttachOpenedHiddenThatComesIntoViewOpeningReportsOnceOpen() async throws {
        let fixture = try await Fixture()
        let store = fixture.store(isViewed: false)
        store.viewDidResize(cols: 80, rows: 24)
        store.setViewed(true)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)
        let focus = await attach.socket.waitForFrame(channel: attach.channel, kind: .focus)
        #expect(focus.payload == Data([1]))
        await store.stop()
        await fixture.finish()
    }

    // MARK: Ending

    @Test func aServerCloseEndsTheSessionWithoutAnError() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        try await attach.socket.deliver(
            HerdrCoreFrame(
                channel: attach.channel, kind: .close,
                payload: Data(#"{"reason":"exited","exit_code":0}"#.utf8)))
        try await Self.until("the end") { store.status == .ended("The session ended.") }
        await fixture.finish()
    }

    /// The core paints no history unless asked (`history` defaults to 0), and
    /// its own client asks only once: a surface that took output keeps its
    /// scrollback, so asking again would repeat every line.
    @Test func aFreshSurfaceAsksForScrollbackAndAReattachOntoOneThatHasItDoesNot() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let first = try await fixture.opened(store)
        #expect(first.params["history"] == .number(10_000))
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        await first.socket.deliverEndOfFile()
        let second = try await fixture.opened(store, count: 2)
        #expect(second.params["history"] == nil)
        await store.stop()
        await fixture.finish()
    }

    @Test func aReattachBeforeAnyOutputStillAsksForScrollback() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let first = try await fixture.opened(store)
        await first.socket.deliverEndOfFile()
        let second = try await fixture.opened(store, count: 2)
        #expect(second.params["history"] == .number(10_000))
        await store.stop()
        await fixture.finish()
    }

    @Test func aHiddenAttachAsksForScrollbackToo() async throws {
        let fixture = try await Fixture()
        let store = fixture.store(isViewed: false)
        let attach = try await fixture.opened(store)
        #expect(attach.params["history"] == .number(10_000))
        await store.stop()
        await fixture.finish()
    }

    @Test func aLinkThatDropsReattachesOnTheNextOneAsAResumedViewerOnTheSameConnection() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        await first.socket.deliverEndOfFile()
        let second = try await fixture.opened(store, count: 2)
        #expect(second.socket !== first.socket)
        #expect(second.params["resumed"] == .bool(true))
        try await fixture.deliverOutput("y", on: second)
        try await Self.until("the reattach") { store.status == .live }
        try await fixture.settle()
        #expect(await second.socket.frames(channel: second.channel, kind: .focus).isEmpty)
        await store.stop()
        await fixture.finish()
    }

    // MARK: Modes

    /// What herdr-core 0.1.13 sends a fresh viewer (`ghostty-vt` `paint`): every
    /// mode off, then the program's own on again.
    private static let firstPaint = Data(
        ("\u{1B}[!p\u{1B}[?2026l\u{1B}[?9l\u{1B}[?1000l\u{1B}[?1001l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1004l"
            + "\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1016l\u{1B}[?2004l\u{1B}[?1l\u{1B}[?66l\u{1B}[?2031l"
            + "\u{1B}[?2048l\u{1B}[=0;1u\u{1B}[?1049l\u{1B}[?1047l\u{1B}[?47l\u{1B}[H\u{1B}[2J"
            + "\u{1B}[?1049h\u{1B}[?2004h\u{1B}[=5;1uscreen").utf8)

    @Test func theFirstPaintLeavesTheModesTheProgramLastSetAndARemountKeepsThem() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let attach = try await fixture.opened(store)
        let first = Sink()
        store.feed.attach(first)
        try await attach.socket.deliver(
            HerdrCoreFrame(channel: attach.channel, kind: .data, payload: Self.firstPaint))
        await attach.socket.waitForCredit(channel: attach.channel, total: Self.firstPaint.count)
        #expect(store.modes.usesBracketedPaste)
        #expect(store.modes.kittyKeyboardFlags == 5)
        #expect(store.modes.isAlternateScreen)

        let remounted = Sink()
        store.feed.attach(remounted)
        #expect(store.modes.usesBracketedPaste)
        #expect(store.modes.kittyKeyboardFlags == 5)
        try await fixture.deliverOutput("\u{1B}[?2004l", on: attach)
        await attach.socket.waitForCredit(channel: attach.channel, total: Self.firstPaint.count + 8)
        #expect(remounted.received == Data("\u{1B}[?2004l".utf8))
        #expect(!store.modes.usesBracketedPaste)
        #expect(store.modes.kittyKeyboardFlags == 5)
        await store.stop()
        await fixture.finish()
    }

    // MARK: Retention

    private static func identity(_ number: Int) -> ShellTerminalIdentity {
        ShellTerminalIdentity(paneID: "t\(number)", tabID: "tab\(number)", terminalID: "t\(number)")
    }

    private func open(
        _ number: Int, in fixture: Fixture, ownerID: UUID, count: Int
    ) async throws -> (entry: TerminalConnectionPool.Entry, attach: (channel: UInt32, params: JSONValue, socket: FakeCoreSocket)) {
        let entry = try await fixture.console.terminalConnections.select(
            hostID: fixture.host.id, identity: Self.identity(number), ownerID: ownerID, generation: nil,
            runTerminal: fixture.runner)
        entry.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach", count: count)
        let attach = try #require(await fixture.scripted.attaches.last)
        #expect(attach.params["terminal"] == .string("t\(number)"))
        return (entry, attach)
    }

    @Test func fiveTerminalsStayOnOneLinkAndTheLeastRecentlyViewedMakesRoomForASixth() async throws {
        let fixture = try await Fixture()
        let pool = fixture.console.terminalConnections
        var opened: [(channel: UInt32, params: JSONValue, socket: FakeCoreSocket)] = []
        for number in 1...5 {
            let owner = UUID()
            let (_, attach) = try await open(number, in: fixture, ownerID: owner, count: number)
            opened.append(attach)
            pool.release(hostID: fixture.host.id, identity: Self.identity(number), ownerID: owner)
        }
        #expect(pool.entries.count == 5)
        let socket = try #require(await fixture.scripted.socket)
        #expect(opened.allSatisfy { $0.socket === socket })
        for attach in opened {
            #expect(await socket.frames(channel: attach.channel, kind: .close).isEmpty)
        }

        // Coming back to the first makes the second the least recently viewed.
        let returning = UUID()
        _ = try #require(
            pool.reclaim(
                hostID: fixture.host.id, identity: Self.identity(1), ownerID: returning, generation: nil))
        pool.release(hostID: fixture.host.id, identity: Self.identity(1), ownerID: returning)

        _ = try await open(6, in: fixture, ownerID: UUID(), count: 6)
        _ = await socket.waitForFrame(channel: opened[1].channel, kind: .close)
        #expect(await socket.frames(channel: opened[0].channel, kind: .close).isEmpty)
        #expect(await socket.frames(channel: opened[2].channel, kind: .close).isEmpty)
        #expect(pool.entries.count == 5)

        #expect(await fixture.scripted.log.filter { $0.hasPrefix("open ") }.count == 1)
        #expect(await fixture.scripted.sockets.count == 1)
        await fixture.finish()
    }

    @Test func aHiddenRetainedTerminalReportsNothingAndComesBackWithFocus() async throws {
        let fixture = try await Fixture()
        let pool = fixture.console.terminalConnections
        let owner = UUID()
        let (entry, attach) = try await open(1, in: fixture, ownerID: owner, count: 1)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the first output") { entry.store.terminalStatus == .live }
        pool.release(hostID: fixture.host.id, identity: Self.identity(1), ownerID: owner)
        try await Self.until("focus lost") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([0])
        }
        let hidden = await attach.socket.frames(channel: attach.channel, kind: .focus).count
        entry.store.terminalFeed.updateDisplayFacts { $0 = Self.facts }
        try await fixture.settle()
        #expect(await attach.socket.frames(channel: attach.channel, kind: .focus).count == hidden)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .facts).isEmpty)

        let returning = UUID()
        _ = try #require(
            pool.reclaim(
                hostID: fixture.host.id, identity: Self.identity(1), ownerID: returning, generation: nil))
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([1]))
        await fixture.finish()
    }

    @Test func aRetainedTerminalWhoseFiveMinutesAreOverClosesItsChannel() async throws {
        let fixture = try await Fixture()
        let pool = TerminalConnectionPool(idleTimeout: .milliseconds(20))
        let owner = UUID()
        let entry = try await pool.select(
            hostID: fixture.host.id, identity: Self.identity(1), ownerID: owner, generation: nil,
            runTerminal: fixture.runner)
        entry.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)
        pool.release(hostID: fixture.host.id, identity: Self.identity(1), ownerID: owner)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(pool.entries.isEmpty)
        await fixture.finish()
    }

    @Test func anAgentIsHeldWhileItsDetailLivesAndFreeOnceItIsGone() async throws {
        final class Detail {}
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = fixture.console.agentTerminals
        let first = UUID()
        var detail: Detail? = Detail()
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: first, holder: detail)
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: first))
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        cache.release(entry, ownerID: first)
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: first))
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        detail = nil
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        await fixture.finish()
    }

    /// The replaced detail's late release finds nothing to undo, and the
    /// timer runs from the release of the detail that took over.
    @Test func aDetailInTheOwnersWindowTakesTheEntryAndAnotherWindowDoesNot() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = AgentTerminalCache(idleTimeout: .milliseconds(20))
        let scene = UUID()
        let replaced = UUID()
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: replaced, sceneID: scene)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)

        let replacement = UUID()
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: replacement))
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: replacement, sceneID: UUID()))
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: replacement, sceneID: scene))

        let taken = cache.acquire(agent: agent, console: fixture.console, ownerID: replacement, sceneID: scene)
        #expect(taken === entry)
        cache.release(entry, ownerID: replaced)
        try await Task.sleep(for: .milliseconds(100))
        #expect(entry.isRetained)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .close).isEmpty)

        cache.release(entry, ownerID: replacement)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(cache.entries.isEmpty)
        await fixture.finish()
    }

    /// A Herdr TUI detail passes no window, so its replacement closes the
    /// entry and attaches anew, as it always has.
    @Test func aDetailWithNoWindowClosesTheEntryItReplaces() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = AgentTerminalCache(idleTimeout: .seconds(300))
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: UUID())
        let replacement = cache.acquire(agent: agent, console: fixture.console, ownerID: UUID())
        #expect(replacement !== entry)
        #expect(!entry.isRetained)
        await cache.suspend()
        await fixture.finish()
    }

    @Test func aWindowThatEndsStartsTheRetentionOfWhatItShows() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = AgentTerminalCache(idleTimeout: .milliseconds(20))
        let scene = UUID()
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: UUID(), sceneID: scene)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)

        cache.sceneDidEnd(UUID())
        try await Task.sleep(for: .milliseconds(100))
        #expect(entry.isRetained)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .close).isEmpty)

        cache.sceneDidEnd(scene)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(cache.entries.isEmpty)
        await fixture.finish()
    }

    /// Going under Changes starts the five minutes; the window closing later
    /// must not start them again.
    @Test func aWindowThatEndsLeavesARunningTimerAlone() async throws {
        final class Detail {}
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = AgentTerminalCache(idleTimeout: .seconds(1))
        let owner = UUID()
        let scene = UUID()
        let detail = Detail()
        let entry = cache.acquire(
            agent: agent, console: fixture.console, ownerID: owner, sceneID: scene, holder: detail)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)

        let released = ContinuousClock.now
        cache.release(entry, ownerID: owner)
        try await Task.sleep(for: .milliseconds(900))
        #expect(cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        cache.sceneDidEnd(scene)
        #expect(!cache.isHeldByAnotherDetail(agent, ownerID: UUID()))
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(ContinuousClock.now - released < .milliseconds(1800))
        withExtendedLifetime(detail) {}
        await fixture.finish()
    }

    @Test func theFiveDefaultMinutesAreWhatTheConsoleRetainsFor() async throws {
        let fixture = try await Fixture()
        #expect(fixture.console.terminalConnections.idleTimeout == .seconds(300))
        #expect(fixture.console.agentTerminals.idleTimeout == .seconds(300))
        await fixture.finish()
    }

    private static let agentRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
        "argv": .array([.string("claude")]), "keep": .bool(false), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "pid": .number(7),
        "foreground": .object([
            "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
            "cwd": .string("/work/app"),
        ]),
        "status": .object(["state": .string("working"), "app": .string("claude-code")]),
        "labels": .object([:]),
    ])

    @Test func aRetainedAgentGoesQuietWhenHiddenAndClosesItsChannelWhenEvicted() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let cache = fixture.console.agentTerminals
        let owner = UUID()
        let entry = cache.acquire(agent: agent, console: fixture.console, ownerID: owner)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)
        #expect(attach.params["terminal"] == .string("t1"))
        #expect(attach.params["takeover"] == nil)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the first output") { entry.attach.terminalStatus == .live }

        cache.release(entry, ownerID: owner)
        try await Self.until("focus lost") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([0])
        }
        #expect(await attach.socket.frames(channel: attach.channel, kind: .close).isEmpty)

        await cache.suspend()
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(await fixture.scripted.log.filter { $0.hasPrefix("open ") }.count == 1)
        await fixture.finish()
    }

    // MARK: Windows

    @Test func aSecondWindowOnAnAgentAlreadyShownIsASecondViewer() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let first = try await fixture.showDetail(of: agent)
        let held = try await fixture.waitForAttach(1, laying: first)

        let second = try await fixture.showDetail(of: agent)
        let viewer = try await fixture.waitForAttach(2, laying: second)

        #expect(viewer.channel != held.channel)
        #expect(viewer.params["terminal"] == .string("t1"))
        #expect(viewer.params["observe"] == nil)
        #expect(viewer.params["takeover"] == nil)
        #expect(first.surface != nil)
        #expect(first.surface !== second.surface)
        #expect(await held.socket.frames(channel: held.channel, kind: .close).isEmpty)
        await first.close()
        await second.close()
        await fixture.finish()
    }

    /// Changes leaves the first window's terminal hidden, not gone. The
    /// second window must not walk off with it, or both windows would share
    /// one surface once the first comes back.
    @Test func aWindowBackFromChangesFindsItsOwnTerminalBesideASecondViewer() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let first = try await fixture.showDetail(of: agent)
        let held = try await fixture.waitForAttach(1, laying: first)
        try await fixture.deliverOutput("x", on: held)
        let surface = try #require(first.surface)

        first.changes.open()
        try await Self.until("the terminal to go quiet under Changes") {
            first.layOut()
            return await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0])
        }

        let second = try await fixture.showDetail(of: agent)
        let viewer = try await fixture.waitForAttach(2, laying: second)
        #expect(second.surface != nil)
        #expect(second.surface !== surface)

        first.changes.close()
        try await Self.until("the first window's terminal to come back") {
            first.layOut()
            return first.surface != nil
        }
        await first.settle()
        #expect(first.surface === surface)
        #expect(second.surface != nil)
        #expect(second.surface !== surface)
        #expect(await fixture.scripted.attaches.count == 2)
        try await Self.until("the first terminal to be viewed again") {
            await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([1])
        }
        #expect(await held.socket.frames(channel: held.channel, kind: .close).isEmpty)
        #expect(await viewer.socket.frames(channel: viewer.channel, kind: .close).isEmpty)
        await first.close()
        await second.close()
        await fixture.finish()
    }

    @Test func aWindowTakesTheRetainedTerminalOfADetailThatIsGone() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let first = try await fixture.showDetail(of: agent)
        let held = try await fixture.waitForAttach(1, laying: first)
        try await fixture.deliverOutput("x", on: held)

        first.selection.showsDetail = false
        try await Self.until("the detail to leave its terminal") {
            first.layOut()
            return await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0])
        }
        try await Self.until("the detail to be gone") {
            first.layOut()
            return !fixture.console.agentTerminals.isHeldByAnotherDetail(agent, ownerID: UUID())
        }

        let second = try await fixture.showDetail(of: agent)
        try await Self.until("the retained terminal to come back") {
            second.layOut()
            return second.surface != nil
        }
        await second.settle()
        #expect(await fixture.scripted.attaches.count == 1)
        #expect(await held.socket.frames(channel: held.channel, kind: .close).isEmpty)
        await first.close()
        await second.close()
        await fixture.finish()
    }

    /// A size-class change replaces the detail while the Agent stays selected,
    /// so the old one never releases. The new one must take its place, or the
    /// old viewer outlives it with no timer running.
    @Test func aDetailRemountedInItsWindowTakesItsTerminalOver() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let window = try await fixture.showDetail(of: agent, sceneID: UUID())
        let held = try await fixture.waitForAttach(1, laying: window)
        try await fixture.deliverOutput("x", on: held)
        let surface = try #require(window.surface)

        window.selection.detailGeneration += 1
        try await Self.until("the new detail's terminal") {
            window.layOut()
            return window.surface != nil
        }
        await window.settle()
        #expect(window.surface === surface)
        #expect(await fixture.scripted.attaches.count == 1)
        #expect(await held.socket.frames(channel: held.channel, kind: .close).isEmpty)

        let resizes = await held.socket.frames(channel: held.channel, kind: .resize).count
        window.window.frame = CGRect(x: 0, y: 0, width: 744, height: 874)
        try await Self.until("the new size on the one channel") {
            window.layOut()
            return await held.socket.frames(channel: held.channel, kind: .resize).count > resizes
        }

        window.selection.showsDetail = false
        try await Self.until("the terminal to go quiet when its Agent is left") {
            window.layOut()
            return await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0])
        }
        try await Self.until("the old and new details to be gone") {
            window.layOut()
            return !fixture.console.agentTerminals.isHeldByAnotherDetail(agent, ownerID: UUID())
        }
        #expect(await held.socket.frames(channel: held.channel, kind: .close).isEmpty)
        await window.close()
        await fixture.finish()
    }

    /// Closing a window ends its detail with the Agent still selected, so the
    /// detail never releases; the scene root says so instead. The terminal
    /// then retains as any other, for another window to come back to.
    @Test func aWindowClosedOnItsAgentLeavesItsTerminalRetained() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let closing = UUID()
        let first = try await fixture.showDetail(of: agent, sceneID: closing)
        let held = try await fixture.waitForAttach(1, laying: first)
        try await fixture.deliverOutput("x", on: held)

        await first.close()
        fixture.console.agentTerminals.sceneDidEnd(closing)
        try await Self.until("the closed window's terminal to go quiet") {
            await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0])
        }

        #expect(!fixture.console.agentTerminals.isHeldByAnotherDetail(agent, ownerID: UUID()))

        let second = try await fixture.showDetail(of: agent, sceneID: UUID())
        try await Self.until("the retained terminal in the other window") {
            second.layOut()
            return second.surface != nil
        }
        await second.settle()
        #expect(await fixture.scripted.attaches.count == 1)
        #expect(await held.socket.frames(channel: held.channel, kind: .close).isEmpty)
        try await Self.until("the terminal to be viewed again") {
            await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([1])
        }
        await second.close()
        await fixture.finish()
    }

    /// A second viewer holds nothing back: it leaves with its detail, however
    /// the detail goes, and the retained terminal beside it stays.
    @Test func aSecondViewerEndsWithItsDetailAndLeavesTheRetainedTerminal() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let first = try await fixture.showDetail(of: agent, sceneID: UUID())
        let held = try await fixture.waitForAttach(1, laying: first)
        let second = try await fixture.showDetail(of: agent, sceneID: UUID())
        let viewer = try await fixture.waitForAttach(2, laying: second)

        second.selection.detailGeneration += 1
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)
        let replacement = try await fixture.waitForAttach(3, laying: second)
        #expect(replacement.channel != viewer.channel)

        await second.close()
        _ = await replacement.socket.waitForFrame(channel: replacement.channel, kind: .close)
        #expect(await held.socket.frames(channel: held.channel, kind: .close).isEmpty)
        await first.close()
        await fixture.finish()
    }
}

/// Whether a window's selection still shows the Agent, as the router says.
@MainActor
@Observable
private final class HostedDetailSelection {
    var showsDetail = true
    /// Bumped to replace the detail while it stays selected, as a size-class
    /// change does.
    var detailGeneration = 0
}

/// Builds its detail in its body, as the Console does, so nothing outside the
/// view graph keeps the detail's state alive after it leaves.
private struct HostedCoreDetail: View {
    let selection: HostedDetailSelection
    let routing: AgentSceneRouting?
    let makeDetail: @MainActor () -> AgentDetailView

    var body: some View {
        NavigationStack {
            if selection.showsDetail {
                makeDetail()
                    .id(selection.detailGeneration)
            } else {
                Text(verbatim: "Agents")
            }
        }
        .environment(\.agentSceneRouting, routing)
    }
}

/// One iPad window showing a core Agent's detail.
@MainActor
private final class CoreDetailWindow {
    let selection: HostedDetailSelection
    let changes: AgentChangesPresentation
    let window: UIWindow

    init(selection: HostedDetailSelection, changes: AgentChangesPresentation, window: UIWindow) {
        self.selection = selection
        self.changes = changes
        self.window = window
    }

    func layOut() { window.layoutIfNeeded() }

    /// The terminal this window shows, while one is in its hierarchy.
    var surface: HeelerTerminalView? {
        AgentSurfaceReplacementTests.terminals(in: window).first
    }

    /// Lets a pop finish and the view updates it set off land.
    func settle() async {
        var budget = PollBudget(.seconds(2))
        while !isNavigationSettled(window.rootViewController), budget.hasTimeLeft {
            try? await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        layOut()
        try? await Task.sleep(for: .milliseconds(100))
        layOut()
    }

    func close() async {
        await hideTestWindowWhenSettled(window)
        window.rootViewController = nil
    }
}
