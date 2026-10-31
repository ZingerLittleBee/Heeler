import Foundation
import GhosttyTerminal
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
        func showDetail(
            of agent: ConsoleAgent, sceneID: UUID? = nil, inputMode: AgentInputMode = .composer,
            readsHostChanges: Bool = false, look: WindowLook = WindowLook()
        ) async throws -> CoreDetailWindow {
            let settings = try Self.makeSettings(look: look)
            let defaults = try #require(UserDefaults(suiteName: "core-detail-\(UUID().uuidString)"))
            let inputModeSettings = AgentInputModeSettings(defaults: defaults)
            inputModeSettings.select(inputMode)
            let selection = HostedDetailSelection()
            let changes =
                readsHostChanges
                ? nil
                : AgentChangesPresentation {
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
                        terminal: settings,
                        inputMode: inputModeSettings,
                        detailSurface: AgentDetailSurfaceSettings(defaults: defaults),
                        hosts: [],
                        activity: activity,
                        keyboardHandoff: handoff,
                        keyboardInset: inset,
                        stage: AgentDetailStage(
                            isVisible: { [selection] in selection.showsDetail },
                            hostID: agent.hostID,
                            console: console,
                            sceneRouting: routing),
                        onSwitch: { _ in },
                        onClosed: {},
                        onSelectTerminal: { _ in },
                        changesPresentation: changes)
                })
            controller.overrideUserInterfaceStyle = look.appearance
            let window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
            return CoreDetailWindow(
                selection: selection, changes: changes, activity: activity, themes: settings.themes,
                window: window)
        }

        /// A window showing a core Terminal's screen, built as the Console
        /// builds it, under a scene root.
        func showShell(
            of terminal: ConsoleTerminal, sceneID: UUID, look: WindowLook = WindowLook()
        ) async throws -> CoreDetailWindow {
            let settings = try Self.makeSettings(look: look)
            let selection = HostedDetailSelection()
            let console = console
            let activity = AppActivityCoordinator()
            let routing = AgentSceneRouting(directory: directory, sceneID: sceneID)
            let controller = UIHostingController(
                rootView: NavigationStack {
                    WorkspaceTerminalDetailView(
                        terminal: terminal,
                        console: console,
                        settings: settings,
                        activity: activity,
                        onSelectAgent: { _ in },
                        onSelectTerminal: { _ in },
                        isSelected: { [selection] in selection.showsDetail },
                        onBack: {})
                }
                .environment(\.agentSceneRouting, routing))
            controller.overrideUserInterfaceStyle = look.appearance
            let window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
            return CoreDetailWindow(
                selection: selection,
                changes: AgentChangesPresentation {
                    ChangesStore(directory: { "/work/app" }) { _ in throw ChangesReadError.unavailable }
                },
                activity: activity, themes: settings.themes, window: window)
        }

        private static func makeSettings(look: WindowLook) throws -> TerminalSettings {
            let defaults = try #require(UserDefaults(suiteName: "core-settings-\(UUID().uuidString)"))
            let themes = TerminalThemeSettings(defaults: defaults)
            themes.select(look.light, for: .light)
            themes.select(look.dark, for: .dark)
            return TerminalSettings(
                themes: themes,
                zoom: TerminalZoomSettings(defaults: defaults),
                fonts: TerminalFontSettings(defaults: defaults),
                snippets: SnippetStore(defaults: defaults))
        }

        /// Two windows on `agent`, as the app registers them, `holder` the one
        /// worked in last. What the scene directory then says of `other`.
        func registerWindows(on agent: ConsoleAgent, holder: UUID, other: UUID) -> HostTerminalAccess {
            for sceneID in [other, holder] {
                let router = AgentNotificationRouter()
                router.agentsDidChange([agent])
                directory.register(sceneID: sceneID, router: router, window: FakeSceneWindow()) {}
                router.path = [agent.id]
                directory.sceneRouteDidChange(sceneID: sceneID)
                directory.sceneDidBecomeActive(sceneID: sceneID)
            }
            return directory.terminalAccess(sceneID: other, hostID: agent.hostID)
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

    /// The request already went out hidden, so nobody but this report tells the
    /// core a viewer is looking now.
    @Test func anAttachOpenedHiddenThatComesIntoViewOpeningReportsOnceOpen() async throws {
        let fixture = try await Fixture()
        await fixture.scripted.holdAttachReplies()
        let store = fixture.store(isViewed: false)
        let attach = try await fixture.opened(store)
        #expect(attach.params["resumed"] == .bool(true))
        #expect(attach.params["display"] == nil)

        store.setViewed(true)
        await fixture.scripted.releaseAttachReplies()

        try await Self.until("focus") {
            await attach.socket.frames(channel: attach.channel, kind: .focus).map(\.payload) == [Data([1])]
        }
        store.feed.updateDisplayFacts { $0 = Self.facts }
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .facts)
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

    // MARK: Kept restarts

    private static func keptRecord(address: String = "t1", argv: String = "vim", pid: Int = 7) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string(argv)]), "keep": .bool(true), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(Double(pid)),
        ])
    }

    /// A kept Terminal in the middle of a restart, as a snapshot lists it.
    private static let restartingRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
        "argv": .array([.string("vim")]), "keep": .bool(true), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "reason": .string("signaled"),
    ])

    private static let finishedRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("finished"),
        "argv": .array([.string("vim")]), "keep": .bool(false), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "reason": .string("exited"), "exit_code": .number(0),
    ])

    /// The order a program's end comes in, since a cursor drops what is not newer.
    private static let eventOrder = ["lost", "restarted", "finished", "foreground", "removed"]

    private static func eventLine(_ type: String, data: JSONValue, terminal: String = "t1") throws -> Data {
        let sequence = 50 + (eventOrder.firstIndex(of: type) ?? 0)
        return try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "method": .string("event"),
                "params": .object([
                    "seq": .number(Double(sequence)), "type": .string(type), "terminal": .string(terminal),
                    "data": data,
                ]),
            ]))
    }

    private static let lostEnd: JSONValue = .object([
        "reason": .string("signaled"), "signal": .number(9),
    ])

    private static let exitedEnd: JSONValue = .object([
        "reason": .string("exited"), "exit_code": .number(0),
    ])

    /// What the core sends a viewer when the program goes.
    private static func deliverClose(on attach: CoreAttach, end: JSONValue = lostEnd) async throws {
        try await attach.socket.deliver(
            HerdrCoreFrame(channel: attach.channel, kind: .close, payload: try JSONEncoder().encode(end)))
    }

    @Test func aLostProgramShowsRestartingAndTheNewShellComesBackWithNoOneAsking() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let sink = Sink()
        store.feed.attach(sink)
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("vim screen", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.deliverClose(on: first)
        try await Self.until("restarting") { store.status == .restarting }
        try await fixture.settle()
        #expect(await fixture.scripted.attaches.count == 1)

        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        let second = try await fixture.opened(store, count: 2)
        #expect(second.params["resumed"] == .bool(true))
        #expect(second.params["history"] == nil)
        #expect(store.status == .restarting)
        try await fixture.deliverOutput("new shell", on: second)
        try await Self.until("the new shell") { store.status == .live }
        #expect(String(data: sink.received, encoding: .utf8) == "vim screennew shell")

        // Typing reaches the shell that came back.
        store.send(Data("ls".utf8))
        try await Self.until("the typed bytes") {
            await second.socket.frames(channel: second.channel, kind: .data).reduce(Data()) { $0 + $1.payload }
                == Data("ls".utf8)
        }
        await store.stop()
        await fixture.finish()
    }

    /// Nothing orders the two channels on this side: the CLOSE can be read
    /// before the event the core sent ahead of it, and neither that wait nor
    /// the restart ever reads as an ended session.
    @Test func aCloseReadBeforeWordOfTheLossNeverReadsAsAnEnd() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await Self.deliverClose(on: first)
        try await Task.sleep(for: .milliseconds(200))
        if case .ended = store.status { Issue.record("read as ended before word of the loss") }

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.until("restarting") { store.status == .restarting }
        await store.stop()
        await fixture.finish()
    }

    /// A slow reader can hear of the whole restart before its CLOSE: the new
    /// shell's process says this is another program.
    @Test func aCloseReadAfterTheRestartReattachesAtOnce() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        try await fixture.settle()
        try await Self.deliverClose(on: first)
        let second = try await fixture.opened(store, count: 2)
        try await fixture.deliverOutput("y", on: second)
        try await Self.until("the reattach") { store.status == .live }
        await store.stop()
        await fixture.finish()
    }

    @Test func aFinishedProgramEndsForGoodWithNoReattach() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await fixture.scripted.deliverEvent(Self.eventLine("finished", data: Self.exitedEnd))
        try await Self.deliverClose(on: first, end: Self.exitedEnd)
        try await Self.until("the end") { store.status == .finished }

        store.retry()
        try await fixture.settle()
        #expect(store.status == .finished)
        #expect(await fixture.scripted.attaches.count == 1)
        await store.stop()
        await fixture.finish()
    }

    @Test func openingATerminalBetweenProgramsWaitsForItsShell() async throws {
        let fixture = try await Fixture(terminals: [Self.restartingRecord])
        let store = fixture.store()
        store.viewDidResize(cols: 80, rows: 24)
        try await Self.until("restarting") { store.status == .restarting }
        try await fixture.settle()
        #expect(await fixture.scripted.attaches.isEmpty)

        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        let attach = try await fixture.opened(store)
        try await fixture.deliverOutput("shell", on: attach)
        try await Self.until("the shell") { store.status == .live }
        await store.stop()
        await fixture.finish()
    }

    @Test func openingATerminalThatEndedAttachesToNothing() async throws {
        let fixture = try await Fixture(terminals: [Self.finishedRecord])
        let store = fixture.store()
        store.viewDidResize(cols: 80, rows: 24)
        try await Self.until("the end") { store.status == .finished }
        try await fixture.settle()
        #expect(await fixture.scripted.attaches.isEmpty)
        await store.stop()
        await fixture.finish()
    }

    /// A core refuses an attach between a program's loss and its new shell.
    /// Asked in that moment, before word of the loss, it is the same restart.
    @Test func anAttachRefusedForALostProgramWaitsForTheShell() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        await fixture.scripted.refuseNextAttach(kind: "unavailable")
        let store = fixture.store()
        store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.until("restarting") { store.status == .restarting }
        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        await fixture.scripted.waitForMethod("terminal.attach", count: 2)
        let attach = try #require(await fixture.scripted.attaches.last)
        try await fixture.deliverOutput("shell", on: attach)
        try await Self.until("the shell") { store.status == .live }
        await store.stop()
        await fixture.finish()
    }

    @Test func anAttachRefusedForAFinishedTerminalEndsIt() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        await fixture.scripted.refuseNextAttach(kind: "finished")
        let store = fixture.store()
        store.viewDidResize(cols: 80, rows: 24)
        try await Self.until("the end") { store.status == .finished }
        await store.stop()
        await fixture.finish()
    }

    /// Stop must not sit behind the wait for a shell that may never come.
    @Test func stoppingWhileRestartingLeavesAtOnce() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store()
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }
        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.deliverClose(on: first)
        try await Self.until("restarting") { store.status == .restarting }

        await store.stop()
        #expect(store.status == .stopped)
        await fixture.finish()
    }

    /// A hidden retained terminal comes back too, and stays quiet.
    @Test func aHiddenAttachComesBackHiddenAfterARestart() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord()])
        let store = fixture.store(viewer: .resumed, isViewed: false)
        let first = try await fixture.opened(store)
        try await fixture.deliverOutput("x", on: first)
        try await Self.until("the first output") { store.status == .live }

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.deliverClose(on: first)
        try await Self.until("restarting") { store.status == .restarting }
        try await fixture.scripted.deliverEvent(
            Self.eventLine("restarted", data: Self.keptRecord(argv: "/bin/zsh", pid: 99)))
        let second = try await fixture.opened(store, count: 2)
        #expect(second.params["resumed"] == .bool(true))
        try await fixture.deliverOutput("y", on: second)
        try await Self.until("the reattach") { store.status == .live }
        try await fixture.settle()
        #expect(await second.socket.frames(channel: second.channel, kind: .focus).isEmpty)
        await store.stop()
        await fixture.finish()
    }

    // MARK: A detail over a kept restart

    private static let keptAgentRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
        "argv": .array([.string("claude")]), "keep": .bool(true), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "pid": .number(7),
        "foreground": .object([
            "pid": .number(7), "name": .string("claude"), "argv": .array([.string("claude")]),
            "cwd": .string("/work/app"),
        ]),
        "status": .object(["state": .string("working"), "app": .string("claude-code")]),
        "labels": .object([:]),
    ])

    private static let restoredShell = keptRecord(argv: "/bin/zsh", pid: 99)

    @Test func anAgentDetailShowsRestartingThenTheRestoredShellInPlace() async throws {
        let fixture = try await Fixture(terminals: [Self.keptAgentRecord])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        let first = try await fixture.waitForAttach(1, laying: detail)
        try await fixture.deliverOutput("agent screen", on: first)
        let retained = try #require(fixture.console.agentTerminals.entries[agent.id])

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.deliverClose(on: first)
        try await Self.until("the restarting state") { detail.reads("Restarting…") }
        #expect(!detail.offers("Reattach"))
        #expect(!detail.reads("Session Ended"))
        #expect(fixture.console.agents.isEmpty)
        #expect(!fixture.console.chatDisplayAgents.contains { $0.id == agent.id })
        let departed = try #require(fixture.console.detailAgent(for: agent.id))
        #expect(departed.agent.status == .unknown)
        #expect(fixture.console.terminals.first?.isRestarting == true)

        // `restarted` changes the inventory's revision, which is when the
        // Console lets go of terminals no Agent holds.
        try await fixture.scripted.deliverEvent(Self.eventLine("restarted", data: Self.restoredShell))
        let second = try await fixture.waitForAttach(2, laying: detail)
        #expect(second.params["resumed"] == .bool(true))
        try await fixture.deliverOutput("new shell", on: second)
        try await Self.until("the shell on screen") { !detail.reads("Restarting…") }
        #expect(!detail.offers("Reattach"))
        #expect(detail.surface != nil)
        #expect(fixture.console.agents.isEmpty)
        #expect(fixture.console.agentTerminals.entries[agent.id] === retained)
        #expect(fixture.console.detailAgent(for: agent.id) != nil)
        #expect(await second.socket.frames(channel: second.channel, kind: .close).isEmpty)
        await detail.close()
        await fixture.finish()
    }

    @Test func anAgentDetailSaysItEndedAndMakesNoReattachAttempt() async throws {
        let fixture = try await Fixture(terminals: [Self.keptAgentRecord])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        let first = try await fixture.waitForAttach(1, laying: detail)
        try await fixture.deliverOutput("agent screen", on: first)
        let retained = try #require(fixture.console.agentTerminals.entries[agent.id])

        try await fixture.scripted.deliverEvent(Self.eventLine("finished", data: Self.exitedEnd))
        try await Self.deliverClose(on: first, end: Self.exitedEnd)
        try await Self.until("the ended state") { detail.reads("Agent Ended") }
        #expect(!detail.offers("Reattach"))
        #expect(!detail.reads("Session Ended"))
        #expect(fixture.console.terminals.isEmpty)
        #expect(fixture.console.agents.isEmpty)
        #expect(fixture.console.detailAgent(for: agent.id) != nil)

        // A later turn of the app's wheel does not bring an attempt.
        detail.layOut()
        try await fixture.settle()
        #expect(await fixture.scripted.attaches.count == 1)
        #expect(fixture.console.agentTerminals.entries[agent.id] === retained)

        // Gone from the core, so there is nothing left to show.
        try await fixture.scripted.deliverEvent(Self.eventLine("removed", data: .object([:])))
        try await Self.until("the core forgets it") {
            fixture.console.detailAgent(for: agent.id) == nil
        }
        await detail.close()
        await fixture.finish()
    }

    @Test func anAgentThatLeftItsShellRunningLeavesNoDetailBehind() async throws {
        let fixture = try await Fixture(terminals: [Self.keptAgentRecord])
        let agent = try #require(fixture.console.agents.first)
        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                "foreground",
                data: .object([
                    "pid": .number(8), "name": .string("zsh"), "argv": .array([.string("/bin/zsh")]),
                    "cwd": .string("/work/app"),
                ])))
        try await Self.until("no Agent") { fixture.console.agents.isEmpty }
        #expect(fixture.console.detailAgent(for: agent.id) == nil)
        await fixture.finish()
    }

    /// The same address can host an Agent again, and that one is on the list.
    @Test func anAgentStartedInTheRestoredShellIsListedAgain() async throws {
        let fixture = try await Fixture(terminals: [Self.keptAgentRecord])
        let agent = try #require(fixture.console.agents.first)
        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.until("no Agent") { fixture.console.agents.isEmpty }
        try await fixture.scripted.deliverEvent(Self.eventLine("restarted", data: Self.restoredShell))
        try await Self.until("the shell") {
            fixture.console.terminals.first?.isRestarting == false
        }
        #expect(fixture.console.departedAgents.map(\.id) == [agent.id])

        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                "foreground",
                data: .object([
                    "pid": .number(120), "name": .string("claude"), "argv": .array([.string("claude")]),
                    "cwd": .string("/work/app"),
                ])))
        try await Self.until("the Agent") { !fixture.console.agents.isEmpty }
        #expect(fixture.console.departedAgents.isEmpty)
        await fixture.finish()
    }

    @Test func aCoreTerminalsScreenShowsRestartingAndComesBack() async throws {
        let fixture = try await Fixture(terminals: [Self.keptRecord(argv: "/bin/zsh")])
        let terminal = try #require(fixture.console.terminals.first)
        let screen = try await fixture.showShell(of: terminal, sceneID: UUID())
        let first = try await fixture.waitForAttach(1, laying: screen)
        try await fixture.deliverOutput("x", on: first)

        try await fixture.scripted.deliverEvent(Self.eventLine("lost", data: Self.lostEnd))
        try await Self.deliverClose(on: first)
        try await Self.until("the restarting state") { screen.reads("Restarting…") }
        #expect(!screen.offers("Reattach"))

        try await fixture.scripted.deliverEvent(Self.eventLine("restarted", data: Self.restoredShell))
        let second = try await fixture.waitForAttach(2, laying: screen)
        try await fixture.deliverOutput("y", on: second)
        try await Self.until("the shell on screen") { !screen.reads("Restarting…") }
        #expect(!screen.offers("Reattach"))
        await screen.close()
        await fixture.finish()
    }

    // MARK: Scrollback

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

    // MARK: What a core Agent's detail offers

    /// The header's More, and the Composer's, whose Add has a button of its own.
    private static let coreAgentMenus: Set<[String]> = [
        ["Terminals", "Changes", "Collapse"],
        ["Back to Console", "Show Chat", "Open Terminal", "Changes", "New Agent", "Skills", "Snippets", "Close Agent"],
    ]
    /// Direct Input has no Add of its own: its More carries the same two items.
    private static let coreDirectInputMenus: Set<[String]> = [
        ["Terminals", "Changes", "Collapse"],
        [
            "Back to Console", "Add Image", "Add File", "Show Chat", "Open Terminal", "Changes", "New Agent", "Skills",
            "Snippets", "Close Agent",
        ],
    ]
    /// On screen for a Host that has them; none are built for a core Host yet.
    private static let notBuiltLabels = ["Take Over", "Take Over Here"]

    /// The Agent is working and the draft blank, so Stop has Send's place. Add and
    /// Send (ADR 0035) wait for the platform the connection reports.
    @Test func aCoreAgentsDetailShowsItsTerminalAndOffersOnlyWhatIsBuilt() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        #expect(agent.agent.status == .working)
        let detail = try await fixture.showDetail(of: agent)
        let attach = try await fixture.waitForAttach(1, laying: detail)
        try await fixture.deliverOutput("x", on: attach)
        #expect(attach.params["takeover"] == nil)
        #expect(detail.surface != nil)

        try await Self.until("the Composer") { detail.offers("Message the Agent") }
        for label in Self.notBuiltLabels { #expect(!detail.offers(label), "\(label)") }
        try await Self.until("Add") { detail.offers("Add") }
        #expect(detail.offers("Stop"))
        #expect(!detail.offers("Send"))
        fixture.console.composerStore(for: agent).replaceDraft(with: "and the tests")
        try await Self.until("Send") { detail.offers("Send") }
        #expect(!detail.offers("Stop"))
        fixture.console.composerStore(for: agent).replaceDraft(with: "")
        try await Self.until("Chat, once the Host's kernel is known") { fixture.console.chatProgram(for: agent) != nil }
        detail.layOut()

        let menus = try await HostedMenu.items(labeled: "More", in: detail.window)
        #expect(Set(menus) == Self.coreAgentMenus, "\(menus)")
        await detail.close()
        await fixture.finish()
    }

    /// Send, Stop, Add and the Blocked card all live in Chat's Composer.
    @Test func aCoreChatOffersEverythingItTypes() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        let attach = try await fixture.waitForAttach(1, laying: detail)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("Chat, once the Host's kernel is known") { fixture.console.chatProgram(for: agent) != nil }
        detail.layOut()

        try await HostedMenu.select("Show Chat", labeled: "More", in: detail.window)
        try await Self.until("Chat") { detail.offers("Show Agent Terminal") }

        try await Self.until("the Composer") { detail.offers("Message the Agent") }
        for label in ["Add", "Stop"] { #expect(detail.offers(label), "\(label)") }
        fixture.console.composerStore(for: agent).replaceDraft(with: "and the tests")
        try await Self.until("Send") { detail.offers("Send") }
        await detail.close()
        await fixture.finish()
    }

    @Test func aCoreChatShowsTheDialogOnScreenAsABlockedCard() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let paint = try ChatFixture.text("screens/core-paint/claude-02-c1-bash-blocked.paint")
        await fixture.scripted.setAttachPaint(Data(paint.utf8))
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        _ = try await fixture.waitForAttach(1, laying: detail)
        try await Self.until("the Composer") { detail.offers("Message the Agent") }
        try await Self.until("Chat, once the Host's kernel is known") { fixture.console.chatProgram(for: agent) != nil }
        detail.layOut()
        try await HostedMenu.select("Show Chat", labeled: "More", in: detail.window)
        try await Self.until("Chat") { detail.offers("Show Agent Terminal") }
        let chat = try #require(fixture.console.chatStore(for: agent, program: .claude))

        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                "status",
                data: .object([
                    "status": .object(["state": .string("blocked"), "app": .string("claude-code")]),
                    "records": .object([:]), "reported": .bool(true),
                ])))
        try await Self.until("the store's card") {
            if case .card = chat.blocked.content { return true }
            return false
        }
        await detail.settle()

        #expect(!detail.offers("Message the Agent"))
        #expect(detail.reads("Yes"), "the card's first option")
        #expect(detail.offers("Show Agent Terminal"))
        await detail.close()
        await fixture.finish()
    }

    /// Native Windows stages through the core and has its own Send ticket,
    /// neither built yet.
    @Test func aNativeWindowsCoreAgentsComposerOffersNoAddAndNoSend() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        await fixture.scripted.helper.configure { $0.platform = .nativeWindows }
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        let hostID = fixture.host.id

        try await Self.until("the Composer") { detail.offers("Message the Agent") }
        try await Self.until("the platform") { fixture.console.hostPlatforms[hostID] == .nativeWindows }
        await Task.yield()
        #expect(!detail.offers("Add"))
        #expect(!detail.offers("Send"))
        await detail.close()
        await fixture.finish()
    }

    /// Stop takes Send's place, through the core and no key of Heeler's, and goes
    /// with the Agent even for a detail still on it.
    @Test
    func aWorkingCoreAgentsStopGoesThroughTheCoreUntilAShellHoldsTheForeground() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        let attach = try await fixture.waitForAttach(1, laying: detail)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("Stop") { detail.offers("Stop") }
        #expect(!detail.offers("Send"))

        let stop = try #require(accessibleElement(labeled: "Stop", in: detail.window))
        #expect(stop.accessibilityActivate())
        await fixture.scripted.waitForMethod("terminal.interrupt")
        await fixture.scripted.answerInterrupts()
        await fixture.scripted.waitForMethod("terminal.get")
        await fixture.scripted.answerTerminalReads(with: Self.agentRecord)
        try await fixture.settle()

        #expect(await fixture.scripted.interrupts.count == 1)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .data).isEmpty)

        try await fixture.scripted.deliverEvent(
            Self.eventLine(
                "foreground",
                data: .object([
                    "pid": .number(7), "name": .string("zsh"), "argv": .array([.string("/bin/zsh")]),
                    "cwd": .string("/work/app"),
                ])))
        try await Self.until("the shell") { fixture.console.agents.isEmpty }
        try await Self.until("Stop to go") { !detail.offers("Stop") }
        #expect(await fixture.scripted.interrupts.count == 1)
        await detail.close()
        await fixture.finish()
    }

    /// Esc does not stop Grok Build's turns, so its terminal Composer keeps Send.
    @Test
    func aWorkingGrokBuildAgentsComposerKeepsSend() async throws {
        guard case .object(var grok) = Self.agentRecord else { return }
        grok["argv"] = .array([.string("grok")])
        grok["foreground"] = .object([
            "pid": .number(40), "name": .string("grok"), "argv": .array([.string("grok")]),
            "cwd": .string("/work/app"),
        ])
        grok["status"] = .object(["state": .string("working"), "app": .string("grok-build")])
        let fixture = try await Fixture(terminals: [.object(grok)])
        let agent = try #require(fixture.console.agents.first)
        #expect(agent.agent.kind == "grok")
        #expect(agent.agent.status == .working)
        let detail = try await fixture.showDetail(of: agent)
        let hostID = fixture.host.id
        try await Self.until("the platform") { fixture.console.hostPlatforms[hostID] == .posix }

        try await Self.until("Send") { detail.offers("Send") }
        #expect(!detail.offers("Stop"))
        await detail.close()
        await fixture.finish()
    }

    /// Stop is for a Working Agent. An idle one has nothing to stop.
    @Test func anIdleCoreAgentsComposerOffersNoStop() async throws {
        guard case .object(var idle) = Self.agentRecord else { return }
        idle["status"] = .object(["state": .string("idle"), "app": .string("claude-code")])
        let fixture = try await Fixture(terminals: [.object(idle)])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        let hostID = fixture.host.id

        try await Self.until("the platform") { fixture.console.hostPlatforms[hostID] == .posix }
        try await Self.until("the Composer") { detail.offers("Message the Agent") }
        #expect(!detail.offers("Stop"))
        await detail.close()
        await fixture.finish()
    }

    /// Stop on native Windows arrives with that platform's own Composer.
    @Test func aNativeWindowsCoreAgentsComposerOffersNoStop() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        await fixture.scripted.helper.configure { $0.platform = .nativeWindows }
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        let hostID = fixture.host.id

        try await Self.until("the platform") { fixture.console.hostPlatforms[hostID] == .nativeWindows }
        try await Self.until("the Composer") { detail.offers("Message the Agent") }
        #expect(!detail.offers("Stop"))
        await detail.close()
        await fixture.finish()
    }

    /// Done per device through the real screen: opening clears it, a turn that
    /// ends with the detail open never reads Done, and one after it left does.
    @Test func aCoreAgentsDetailClearsItsDoneAndSeesTheTurnsThatEndWhileItIsOpen() async throws {
        var line = 100
        func event(_ type: String, _ data: JSONValue) -> Data {
            line += 1
            return (try? JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"), "method": .string("event"),
                "params": .object([
                    "seq": .number(Double(line)), "type": .string(type), "terminal": .string("t1"),
                    "data": data,
                ]),
            ]))) ?? Data()
        }
        func status(_ word: String) -> Data {
            event(
                "status",
                .object([
                    "status": .object(["state": .string(word), "app": .string("claude-code")]),
                    "records": .object([:]), "reported": .bool(true),
                ]))
        }
        func turn(_ count: Int, _ word: String) -> Data {
            event("turn", .object(["turn": .number(Double(count)), "state": .string(word)]))
        }

        guard case .object(var finished) = Self.agentRecord else { return }
        finished["status"] = .object(["state": .string("done"), "app": .string("claude-code")])
        finished["turn"] = .number(1)
        finished["reported"] = .bool(true)
        let fixture = try await Fixture(terminals: [.object(finished)])
        let agent = try #require(fixture.console.agents.first)
        #expect(agent.agent.status == .done)
        func current() -> AgentStatus? { fixture.console.agents.first?.agent.status }

        let detail = try await fixture.showDetail(of: agent)
        try await Self.until("opening to clear Done") {
            detail.layOut()
            return current() == .idle
        }
        let attach = try await fixture.waitForAttach(1, laying: detail)
        try await fixture.deliverOutput("x", on: attach)

        try await fixture.scripted.deliverEvent(status("working"))
        try await Self.until("the next turn") { current() == .working }
        try await fixture.scripted.deliverEvent(status("done"))
        try await fixture.scripted.deliverEvent(turn(2, "done"))
        try await fixture.scripted.deliverEvent(event("title", .object(["title": .string("ended")])))
        try await Self.until("the turn's end") {
            detail.layOut()
            return fixture.console.agents.first?.agent.terminalTitle == "ended"
        }
        #expect(current() == .idle)

        detail.selection.showsDetail = false
        try await Self.until("the detail to leave its terminal") {
            detail.layOut()
            return await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([0])
        }
        try await fixture.scripted.deliverEvent(status("working"))
        try await Self.until("another turn") { current() == .working }
        try await fixture.scripted.deliverEvent(status("done"))
        try await fixture.scripted.deliverEvent(turn(3, "done"))
        try await Self.until("Done for the turn nobody was shown") { current() == .done }

        await detail.close()
        await fixture.finish()
    }

    @Test func aCoreAgentsDirectInputOffersOnlyWhatIsBuiltAndTypesIntoItsAttach() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent, inputMode: .direct)
        let attach = try await fixture.waitForAttach(1, laying: detail)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("Direct Input") { detail.offers("Escape") }
        for label in Self.notBuiltLabels { #expect(!detail.offers(label), "\(label)") }
        let hostID = fixture.host.id
        try await Self.until("uploads") { fixture.console.capabilities(for: hostID).uploads }
        try await Self.until("Chat, once the Host's kernel is known") { fixture.console.chatProgram(for: agent) != nil }
        detail.layOut()

        let menus = try await HostedMenu.items(labeled: "More", in: detail.window)
        #expect(Set(menus) == Self.coreDirectInputMenus, "\(menus)")

        let escape = try #require(accessibleElement(labeled: "Escape", in: detail.window))
        #expect(escape.accessibilityActivate())
        let key = await attach.socket.waitForFrame(channel: attach.channel, kind: .data)
        #expect(key.payload == Data([0x1B]))

        (try #require(detail.surface) as UIKeyInput).insertText("hi")
        try await Self.until("what the user typed") {
            let typed = await attach.socket.frames(channel: attach.channel, kind: .data)
            return typed.dropFirst().reduce(into: Data()) { $0.append($1.payload) } == Data("hi".utf8)
        }
        await detail.close()
        await fixture.finish()
    }

    /// The menu's own entry, on the store the detail builds for itself, reads
    /// through the Host's services rather than a Herdr TUI transport.
    @Test func aCoreAgentsChangesEntryOpensTheHostsChanges() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        await fixture.scripted.setChanges(
            CheckoutChangesRead(
                changes: CheckoutChanges(
                    checkout: CheckoutLocation(
                        topLevel: Data("/work/app".utf8), isLinkedWorktree: false, displayPath: "/work/app"),
                    head: CheckoutHead(branch: .named("main"), commit: "abc", latestCommit: nil),
                    files: [
                        ChangedFile(
                            path: Data("src/app.swift".utf8), originalPath: nil, kind: .modified,
                            staging: .unstaged)
                    ]),
                directoryPrefix: Data()))
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent, readsHostChanges: true)
        _ = try await fixture.waitForAttach(1, laying: detail)
        try await Self.until("the Composer") { detail.offers("Message the Agent") }
        #expect(!detail.reads("app.swift"))

        try await HostedMenu.select("Changes", labeled: "More", in: detail.window)

        try await Self.until("the Host's changed file on screen") { detail.reads("app.swift") }
        #expect(await fixture.scripted.changesReads.allSatisfy { $0.directory == "/work/app" })
        await detail.close()
        await fixture.finish()
    }

    @Test func aCoreAgentsSkillsEntryListsTheHostsSkills() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        await fixture.scripted.setSkills([AgentSkill(scope: .project, name: "lab-review", description: nil)])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        _ = try await fixture.waitForAttach(1, laying: detail)
        try await Self.until("the Composer") { detail.offers("Message the Agent") }

        try await HostedMenu.select("Skills", labeled: "More", in: detail.window)

        try await Self.until("the Host's skill on screen") { detail.reads("lab-review") }
        #expect(
            await fixture.scripted.skillQueries.last
                == SkillListQuery(kind: .claude, projectRoot: "/work/app"))
        await detail.close()
        await fixture.finish()
    }

    @Test func aCoreAgentsDrawerOffersNewTerminal() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord, Self.shellRecord(address: "t2")])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent)
        _ = try await fixture.waitForAttach(1, laying: detail)
        try await Self.until("the Composer") { detail.offers("Message the Agent") }

        try await HostedMenu.select("Terminals", labeled: "More", in: detail.window)

        try await Self.until("the drawer") { detail.offers("Hide Workspace terminals") }
        #expect(detail.offers("New Terminal"))
        await detail.close()
        await fixture.finish()
    }

    /// The directory does say another window holds the Host's channel: a core
    /// Host has no channel to hand over, so this window just shows its terminal.
    @Test func aWindowBesideAnotherOnACoreHostIsLiveWithNoOfferToTakeOver() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let other = UUID()
        #expect(
            fixture.registerWindows(on: agent, holder: UUID(), other: other)
                == .liveInAnotherWindow(canTakeOver: true))

        let detail = try await fixture.showDetail(of: agent, sceneID: other)
        let attach = try await fixture.waitForAttach(1, laying: detail)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the Composer") { detail.offers("Message the Agent") }

        #expect(detail.surface != nil)
        #expect(!detail.offers("Live in Another Window"))
        #expect(!detail.offers(LiveInAnotherWindowPresentation.takeOverTitle))
        await detail.close()
        await fixture.finish()
    }

    // MARK: What a shown terminal tells the core

    /// A theme's colors as the core takes them, written out so that neither the
    /// catalog nor the code under test supplies what it is compared with.
    private struct ReportedColors {
        let foreground: String
        let background: String
        let cursor: String

        func match(_ display: JSONValue?) -> Bool {
            display?["fg"] == .string(foreground) && display?["bg"] == .string(background)
                && display?["cursor"] == .string(cursor)
        }
    }

    private static let dracula = ReportedColors(foreground: "#f8f8f2", background: "#282a36", cursor: "#f8f8f2")
    private static let nord = ReportedColors(foreground: "#d8dee9", background: "#2e3440", cursor: "#eceff4")
    private static let zenburn = ReportedColors(foreground: "#dcdccc", background: "#3f3f3f", cursor: "#73635a")

    /// A screen that reads the wrong slot, or no slot, reports something else.
    private static let draculaInLight = WindowLook(light: .dracula, dark: .nord, appearance: .light)

    private typealias CoreAttach = (channel: UInt32, params: JSONValue, socket: FakeCoreSocket)

    private static func lastFacts(on attach: CoreAttach) async -> JSONValue? {
        guard let frame = await attach.socket.frames(channel: attach.channel, kind: .facts).last else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: frame.payload)
    }

    /// The attach opens with the screen's colors, and FACTS brings the core the
    /// cell the surface measures and whatever it measures next.
    private static func checkTellsTheCoreItsColorsAndCell(
        _ screen: CoreDetailWindow, on fixture: Fixture
    ) async throws {
        let attach = try await fixture.waitForAttach(1, laying: screen)
        #expect(dracula.match(attach.params["display"]), "\(attach.params)")

        try await until("the cell the surface measured") {
            screen.layOut()
            guard let facts = await lastFacts(on: attach), dracula.match(facts),
                case .array(let cell)? = facts["cell"], case .number(let width)? = cell.first,
                case .number(let height)? = cell.last
            else { return false }
            return width > 0 && height > 0
        }

        try #require(screen.surface).terminalDidResize(
            TerminalGridMetrics(
                columns: 40, rows: 20, widthPixels: 680, heightPixels: 660,
                cellWidthPixels: 17, cellHeightPixels: 33))
        try await until("the cell the surface measured next") {
            let facts = await lastFacts(on: attach)
            return facts?["cell"] == .array([.number(17), .number(33)]) && dracula.match(facts)
        }
    }

    /// The appearance and the theme picked in Settings each reach the core.
    private static func checkTellsTheCoreWhatItShowsNext(
        _ screen: CoreDetailWindow, on fixture: Fixture
    ) async throws {
        let attach = try await fixture.waitForAttach(1, laying: screen)
        try await until("the opening colors") { dracula.match(await lastFacts(on: attach)) }

        screen.setAppearance(.dark)
        try await until("the other appearance's colors") {
            screen.layOut()
            return nord.match(await lastFacts(on: attach))
        }

        screen.themes.select(.zenburn, for: .dark)
        try await until("the theme picked in Settings") {
            screen.layOut()
            return zenburn.match(await lastFacts(on: attach))
        }
    }

    @Test(arguments: [AgentInputMode.composer, .direct])
    func aCoreAgentsDetailTellsTheCoreItsColorsAndCell(inputMode: AgentInputMode) async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent, inputMode: inputMode, look: Self.draculaInLight)
        try await Self.checkTellsTheCoreItsColorsAndCell(detail, on: fixture)
        await detail.close()
        await fixture.finish()
    }

    @Test func aCoreTerminalsScreenTellsTheCoreItsColorsAndCell() async throws {
        let fixture = try await Fixture(terminals: [Self.shellRecord])
        let terminal = try #require(fixture.console.terminals.first)
        let screen = try await fixture.showShell(of: terminal, sceneID: UUID(), look: Self.draculaInLight)
        try await Self.checkTellsTheCoreItsColorsAndCell(screen, on: fixture)
        await screen.close()
        await fixture.finish()
    }

    @Test func aCoreAgentsDetailTellsTheCoreWhatItShowsNext() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent, look: Self.draculaInLight)
        try await Self.checkTellsTheCoreWhatItShowsNext(detail, on: fixture)
        await detail.close()
        await fixture.finish()
    }

    @Test func aCoreTerminalsScreenTellsTheCoreWhatItShowsNext() async throws {
        let fixture = try await Fixture(terminals: [Self.shellRecord])
        let terminal = try #require(fixture.console.terminals.first)
        let screen = try await fixture.showShell(of: terminal, sceneID: UUID(), look: Self.draculaInLight)
        try await Self.checkTellsTheCoreWhatItShowsNext(screen, on: fixture)
        await screen.close()
        await fixture.finish()
    }

    /// The theme can change while Changes covers the terminal, and then only
    /// coming back tells the core.
    @Test func aHiddenCoreAgentTellsTheCoreItsNewColorsOnlyOnceItIsBack() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let detail = try await fixture.showDetail(of: agent, look: Self.draculaInLight)
        let attach = try await fixture.waitForAttach(1, laying: detail)
        try await Self.until("the opening colors") { Self.dracula.match(await Self.lastFacts(on: attach)) }

        try #require(detail.changes).open()
        try await Self.until("the terminal to go quiet under Changes") {
            detail.layOut()
            return await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([0])
        }
        let reportsBefore = await attach.socket.frames(channel: attach.channel, kind: .facts).count

        detail.themes.select(.zenburn, for: .light)
        await detail.settle()
        try await fixture.settle()
        #expect(await attach.socket.frames(channel: attach.channel, kind: .facts).count == reportsBefore)
        #expect(await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([0]))

        try #require(detail.changes).close()
        try await Self.until("the new colors once it is back") {
            detail.layOut()
            return Self.zenburn.match(await Self.lastFacts(on: attach))
        }
        #expect(await attach.socket.frames(channel: attach.channel, kind: .focus).last?.payload == Data([1]))
        await detail.close()
        await fixture.finish()
    }

    /// Each viewer answers for its own window: the core's size leader decides
    /// which colors a program hears.
    @Test func aSecondWindowTellsTheCoreItsOwnColorsAndCell() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let first = try await fixture.showDetail(of: agent, look: Self.draculaInLight)
        let held = try await fixture.waitForAttach(1, laying: first)

        let second = try await fixture.showDetail(
            of: agent, look: WindowLook(light: .dracula, dark: .nord, appearance: .dark))
        let viewer = try await fixture.waitForAttach(2, laying: second)

        #expect(Self.dracula.match(held.params["display"]))
        #expect(Self.nord.match(viewer.params["display"]))
        try await Self.until("the second window's cell") {
            second.layOut()
            let facts = await Self.lastFacts(on: viewer)
            return facts?["cell"] != nil && Self.nord.match(facts)
        }
        #expect(Self.dracula.match(await Self.lastFacts(on: held)))
        await first.close()
        await second.close()
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

        try #require(first.changes).open()
        try await Self.until("the terminal to go quiet under Changes") {
            first.layOut()
            return await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0])
        }

        let second = try await fixture.showDetail(of: agent)
        let viewer = try await fixture.waitForAttach(2, laying: second)
        #expect(second.surface != nil)
        #expect(second.surface !== surface)

        try #require(first.changes).close()
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
        fixture.console.sceneDidEnd(closing)
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

    /// A closed window's detail may get a late update while the app comes
    /// back; it must not take back the terminal it has let go of.
    @Test func aClosedWindowsDetailDoesNotTakeItsTerminalBack() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let closing = UUID()
        let window = try await fixture.showDetail(of: agent, sceneID: closing)
        let held = try await fixture.waitForAttach(1, laying: window)
        try await fixture.deliverOutput("x", on: held)
        fixture.console.sceneDidEnd(closing)
        try await Self.until("the closed window's terminal to go quiet") {
            await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0])
        }

        window.activity.didBecomeActive()
        await window.settle()
        try await fixture.settle()

        #expect(await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0]))
        #expect(!fixture.console.agentTerminals.isHeldByAnotherDetail(agent, ownerID: UUID()))
        await window.close()
        await fixture.finish()
    }

    /// SwiftUI promises no `onDisappear` for a closed window, and a second
    /// viewer's only other way out is its detail's.
    @Test func aSecondViewerClosesWithItsWindowWhenItsDetailHearsNothing() async throws {
        let fixture = try await Fixture(terminals: [Self.agentRecord])
        let agent = try #require(fixture.console.agents.first)
        let first = try await fixture.showDetail(of: agent, sceneID: UUID())
        let held = try await fixture.waitForAttach(1, laying: first)
        let closing = UUID()
        let second = try await fixture.showDetail(of: agent, sceneID: closing)
        let viewer = try await fixture.waitForAttach(2, laying: second)

        fixture.console.sceneDidEnd(closing)
        _ = await viewer.socket.waitForFrame(channel: viewer.channel, kind: .close)

        second.activity.didBecomeActive()
        await second.settle()
        try await fixture.settle()
        #expect(await fixture.scripted.attaches.count == 2)
        #expect(await held.socket.frames(channel: held.channel, kind: .close).isEmpty)
        await second.close()
        await first.close()
        await fixture.finish()
    }

    // MARK: Shell Terminal windows

    private static func shellRecord(address: String) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
        ])
    }

    private static let shellRecord = shellRecord(address: "t1")

    @Test func aCoreTerminalThatEndsOffersReattachAndNoTakeOver() async throws {
        let fixture = try await Fixture(terminals: [Self.shellRecord])
        let terminal = try #require(fixture.console.terminals.first)
        let screen = try await fixture.showShell(of: terminal, sceneID: UUID())
        let attach = try await fixture.waitForAttach(1, laying: screen)
        try await attach.socket.deliver(
            HerdrCoreFrame(
                channel: attach.channel, kind: .close,
                payload: Data(#"{"reason":"exited","exit_code":0}"#.utf8)))

        try await Self.until("the ended screen") { screen.offers("Reattach") }
        #expect(!screen.offers("Take Over"))
        await screen.close()
        await fixture.finish()
    }

    @Test func aCoreTerminalsMenusOfferCloseAndItsDrawerOffersNewTerminal() async throws {
        let fixture = try await Fixture(terminals: [Self.shellRecord])
        let terminal = try #require(fixture.console.terminals.first)
        let screen = try await fixture.showShell(of: terminal, sceneID: UUID())
        let attach = try await fixture.waitForAttach(1, laying: screen)
        try await fixture.deliverOutput("x", on: attach)
        try await Self.until("the terminal's menu") { screen.offers("More") }

        let menus = try await HostedMenu.items(labeled: "More", in: screen.window)
        #expect(menus == [["Terminals", "Collapse"], ["Back to Console", "Close Terminal"]], "\(menus)")

        try await HostedMenu.select("Terminals", labeled: "More", in: screen.window)
        try await Self.until("the drawer") { screen.offers("Hide Workspace terminals") }
        #expect(screen.offers("New Terminal"))
        await screen.close()
        await fixture.finish()
    }

    /// Closing the window changes nothing the screen's selection reads, so
    /// the screen never releases; the scene root says so instead. The Terminal
    /// then retains as any other, for another window to come back to, where it
    /// used to read as already open in a window that no longer exists.
    @Test func aWindowClosedOnAShellTerminalLeavesItRetainedForAnother() async throws {
        let fixture = try await Fixture(terminals: [Self.shellRecord])
        let terminal = try #require(fixture.console.terminals.first)
        let closing = UUID()
        let first = try await fixture.showShell(of: terminal, sceneID: closing)
        let held = try await fixture.waitForAttach(1, laying: first)
        try await fixture.deliverOutput("x", on: held)

        fixture.console.sceneDidEnd(UUID())
        try await fixture.settle()
        #expect(await held.socket.frames(channel: held.channel, kind: .focus).last?.payload != Data([0]))

        await first.close()
        fixture.console.sceneDidEnd(closing)
        try await Self.until("the closed window's terminal to go quiet") {
            await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0])
        }

        let second = try await fixture.showShell(of: terminal, sceneID: UUID())
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

    @Test func aWindowThatEndsStartsTheFiveMinutesOfTheShellItShows() async throws {
        let fixture = try await Fixture()
        let pool = TerminalConnectionPool(idleTimeout: .milliseconds(20))
        let scene = UUID()
        let entry = try await pool.select(
            hostID: fixture.host.id, identity: Self.identity(1), ownerID: UUID(), sceneID: scene,
            generation: nil, runTerminal: fixture.runner)
        entry.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)

        pool.sceneDidEnd(UUID()) { _ in true }
        pool.sceneDidEnd(scene) { _ in false }
        try await Task.sleep(for: .milliseconds(100))
        #expect(pool.entries.count == 1)

        pool.sceneDidEnd(scene) { $0 == fixture.host.id }
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        #expect(pool.entries.isEmpty)
        await fixture.finish()
    }

    /// Eviction skips what a window shows, so a closed window's Shell would
    /// hold its slot for as long as the app runs.
    @Test func aWindowThatEndsGivesUpTheSlotOfTheShellItShows() async throws {
        let fixture = try await Fixture()
        let pool = TerminalConnectionPool(maximumShellsPerHost: 1)
        let scene = UUID()
        let entry = try await pool.select(
            hostID: fixture.host.id, identity: Self.identity(1), ownerID: UUID(), sceneID: scene,
            generation: nil, runTerminal: fixture.runner)
        entry.store.viewDidResize(cols: 80, rows: 24)
        await fixture.scripted.waitForMethod("terminal.attach")
        let attach = try #require(await fixture.scripted.attaches.last)
        await #expect(throws: TerminalConnectionPool.Failure.self) {
            try await pool.select(
                hostID: fixture.host.id, identity: Self.identity(2), ownerID: UUID(), sceneID: UUID(),
                generation: nil, runTerminal: fixture.runner)
        }

        pool.sceneDidEnd(scene) { _ in true }
        _ = try await pool.select(
            hostID: fixture.host.id, identity: Self.identity(2), ownerID: UUID(), sceneID: UUID(),
            generation: nil, runTerminal: fixture.runner)
        _ = await attach.socket.waitForFrame(channel: attach.channel, kind: .close)
        await pool.suspend()
        await fixture.finish()
    }

    /// A load the closing window cancelled, or one still queued when it
    /// closed, has nobody left to release what it gets.
    @Test(arguments: [true, false])
    func aWindowClosedWhileItsTerminalOpensLeavesItFree(screenDisappears: Bool) async throws {
        let fixture = try await Fixture(terminals: [Self.shellRecord])
        let terminal = try #require(fixture.console.terminals.first)
        let pool = fixture.console.terminalConnections
        // A teardown ahead in the pool's queue holds the screen's load back.
        let opened = ScriptedTransportCallGate()
        await opened.open()
        let teardown = ScriptedTransportCallGate()
        let busy = try await pool.select(
            hostID: fixture.host.id, identity: Self.identity(9), ownerID: UUID(), generation: nil,
            runTerminal: Self.gatedRunner(opened: opened, teardown: teardown))
        busy.store.viewDidResize(cols: 80, rows: 24)
        await opened.waitForEntry()
        let removing = Task { await pool.remove(hostID: fixture.host.id, identity: Self.identity(9)) }
        await teardown.waitForEntry()

        let closing = UUID()
        let window = try await fixture.showShell(of: terminal, sceneID: closing)
        if screenDisappears { await window.close() }
        fixture.console.sceneDidEnd(closing)
        await teardown.open()
        await removing.value
        try await Task.sleep(for: .milliseconds(100))

        let other = try await pool.select(
            hostID: fixture.host.id, identity: ShellTerminalIdentity(
                paneID: terminal.paneID, tabID: terminal.tabID, terminalID: terminal.terminalID),
            ownerID: UUID(), sceneID: UUID(), generation: nil, runTerminal: fixture.runner)
        #expect(other.store.identity.terminalID == terminal.terminalID)
        if !screenDisappears { await window.close() }
        await fixture.finish()
    }

    /// `.task(id:)` runs again when the app comes back, in a screen whose
    /// window closed without telling it.
    @Test func aClosedWindowsScreenDoesNotTakeItsTerminalBack() async throws {
        let fixture = try await Fixture(terminals: [Self.shellRecord])
        let terminal = try #require(fixture.console.terminals.first)
        let closing = UUID()
        let window = try await fixture.showShell(of: terminal, sceneID: closing)
        let held = try await fixture.waitForAttach(1, laying: window)
        try await fixture.deliverOutput("x", on: held)
        fixture.console.sceneDidEnd(closing)
        try await Self.until("the closed window's terminal to go quiet") {
            await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0])
        }

        window.activity.didBecomeActive()
        await window.settle()
        try await fixture.settle()

        #expect(await held.socket.frames(channel: held.channel, kind: .focus).last?.payload == Data([0]))
        #expect(
            fixture.console.terminalConnections.reclaim(
                hostID: fixture.host.id,
                identity: ShellTerminalIdentity(
                    paneID: terminal.paneID, tabID: terminal.tabID, terminalID: terminal.terminalID),
                ownerID: UUID(), sceneID: UUID(), generation: nil) != nil)
        await window.close()
        await fixture.finish()
    }

    /// A window SwiftUI brought back is a window again.
    @Test func aWindowThatComesBackHasNotEnded() async throws {
        let fixture = try await Fixture()
        let scene = UUID()
        #expect(!fixture.console.hasSceneEnded(nil, on: fixture.host.id))
        #expect(!fixture.console.hasSceneEnded(scene, on: fixture.host.id))
        fixture.console.sceneDidEnd(scene)
        #expect(fixture.console.hasSceneEnded(scene, on: fixture.host.id))
        fixture.console.sceneDidStart(scene)
        #expect(!fixture.console.hasSceneEnded(scene, on: fixture.host.id))
        await fixture.finish()
    }

    /// One Shell channel at a time still holds on Herdr TUI: a window's end
    /// changes nothing there.
    @Test func aHerdrTUIWindowThatEndsLeavesItsShellAsItWas() async throws {
        let console = ConsoleStore(makeSession: { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "unused") },
                keepalive: nil)
        })
        let host = Host(address: "tui.example", username: "dev", serverKind: .herdrTUI)
        console.setHosts([host])
        let pool = console.terminalConnections
        let scene = UUID()
        let owner = UUID()
        _ = try await pool.select(
            hostID: host.id, identity: Self.identity(1), ownerID: owner, sceneID: scene,
            generation: nil, runTerminal: { _, _ in })

        console.sceneDidEnd(scene)

        #expect(!console.hasSceneEnded(scene, on: host.id))
        await #expect(throws: TerminalConnectionPool.Failure.self) {
            try await pool.select(
                hostID: host.id, identity: Self.identity(1), ownerID: UUID(), sceneID: UUID(),
                generation: nil, runTerminal: { _, _ in })
        }
        await pool.suspend()
        console.setHosts([])
    }

    /// Opens a session whose teardown waits for `teardown`.
    private static func gatedRunner(
        opened: ScriptedTransportCallGate, teardown: ScriptedTransportCallGate
    ) -> TerminalSessionRunner {
        { _, handler in
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            let input = TerminalAttachInputQueue()
            let session = TerminalAttachSession(output: { stream }, input: input) {
                await teardown.waitUntilOpen()
                input.finish()
                continuation.finish()
            }
            await opened.waitUntilOpen()
            try await handler.runEndingSession(session)
        }
    }
}

/// The theme in each of a test window's two slots and the appearance it shows.
private struct WindowLook {
    var light = TerminalThemeOption.vesper
    var dark = TerminalThemeOption.vesper
    var appearance = UIUserInterfaceStyle.unspecified
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
        // A hosting controller has no SwiftUI scene to say so.
        .environment(\.scenePhase, .active)
    }
}

/// One iPad window showing a core Agent's detail.
@MainActor
private final class CoreDetailWindow {
    let selection: HostedDetailSelection
    /// The Changes the test handed the detail. Nil: the detail built its own.
    let changes: AgentChangesPresentation?
    let activity: AppActivityCoordinator
    let themes: TerminalThemeSettings
    let window: UIWindow

    init(
        selection: HostedDetailSelection, changes: AgentChangesPresentation?,
        activity: AppActivityCoordinator, themes: TerminalThemeSettings, window: UIWindow
    ) {
        self.selection = selection
        self.changes = changes
        self.activity = activity
        self.themes = themes
        self.window = window
    }

    /// Changes the appearance this window shows, as the system does.
    func setAppearance(_ appearance: UIUserInterfaceStyle) {
        window.rootViewController?.overrideUserInterfaceStyle = appearance
    }

    func layOut() { window.layoutIfNeeded() }

    /// Whether accessibility finds a control or text with this label.
    func offers(_ label: String) -> Bool {
        layOut()
        return accessibleElement(labeled: label, in: window) != nil
    }

    /// Whether anything on screen, sheets included, reads with this text.
    func reads(_ text: String) -> Bool {
        layOut()
        return accessibleElements(in: window).contains { $0.accessibilityLabel?.contains(text) == true }
            || window.rootViewController?.presentedViewController.map { sheet in
                accessibleElements(in: sheet.view).contains { $0.accessibilityLabel?.contains(text) == true }
            } == true
    }

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
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        await hideTestWindowWhenSettled(window)
        window.rootViewController = nil
    }
}
