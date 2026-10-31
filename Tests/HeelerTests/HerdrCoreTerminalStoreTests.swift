import Foundation
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

    @Test func theFiveDefaultMinutesAreWhatTheConsoleRetainsFor() async throws {
        let fixture = try await Fixture()
        #expect(fixture.console.terminalConnections.idleTimeout == .seconds(300))
        #expect(fixture.console.agentTerminals.idleTimeout == .seconds(300))
        await fixture.finish()
    }

    @Test func aRetainedAgentGoesQuietWhenHiddenAndClosesItsChannelWhenEvicted() async throws {
        let record: JSONValue = .object([
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
        let fixture = try await Fixture(terminals: [record])
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
}
