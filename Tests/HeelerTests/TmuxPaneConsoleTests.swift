import Foundation
import GhosttyTerminal
import Testing

@testable import Heeler

/// What an Attach on a tmux Pane gets from its Host session (ADR 0043): the
/// connection a server answered on, or why there is none.
@Suite("tmux Host session attach", .timeLimit(.minutes(1)))
struct TmuxHostSessionAttachTests {
    private func session(
        over tmux: ScriptedTmuxHost, keepalive: KeepalivePolicy? = KeepalivePolicy(interval: .milliseconds(10))
    ) -> TmuxHostSession {
        TmuxHostSession(
            storedPaths: ScriptedTmuxHost.paths(),
            connect: { paths in await tmux.transport(socketName: "default", storedPaths: paths) },
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
            keepalive: keepalive, settledLoopLife: .seconds(60))
    }

    private func waitUntil(
        _ what: String, _ condition: () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    @Test func anAttachWaitsForAServerToAnswer() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.stopServer()
        let session = session(over: tmux)
        await session.resume()
        let attach = Task { try await session.withAttachTransport { $0.server.instance } }
        try await waitUntil("the attach to wait") { await session.attachWaiterCount == 1 }

        await tmux.startServer()
        #expect(try await attach.value == ScriptedTmuxHost.instance)
        await session.end()
    }

    @Test func anAttachAfterTheRunStoppedForGoodGetsWhatStoppedIt() async throws {
        let session = TmuxHostSession(
            storedPaths: nil, connect: { _ in throw TransportError.authenticationFailed }, keepalive: nil)
        let updates = Task {
            for await update in session.updates {
                if case .status(.failed) = update { return }
            }
        }
        await session.resume()
        await updates.value
        await #expect(throws: TransportError.authenticationFailed) {
            try await session.withAttachTransport { _ in }
        }
        await session.end()
    }

    @Test func endingTheSessionEndsTheAttachesWaitingOnIt() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.stopServer()
        let session = session(over: tmux)
        await session.resume()
        let attach = Task { try await session.withAttachTransport { _ in } }
        try await waitUntil("the attach to wait") { await session.attachWaiterCount == 1 }

        await session.end()
        await #expect(throws: TransportError.cancelled) { try await attach.value }
    }

    /// Nothing else would notice before the next ask, which may be a while.
    @Test func anAttachThatFindsTheConnectionClosedWaitsForTheNextOne() async throws {
        let tmux = ScriptedTmuxHost()
        let session = session(over: tmux, keepalive: nil)
        await session.resume()
        let first = try await session.withAttachTransport { $0.generation }

        await tmux.dropConnections()
        let next = try await session.withAttachTransport { $0.generation }
        #expect(next != first)
        #expect(await tmux.log.filter { $0 == "probe stored" }.count == 2)
        await session.end()
    }
}

/// A tmux Pane's screen from the store down: the real Console, Host session
/// and tmux transport, with the SSH connection and tmux scripted.
@MainActor
@Suite("tmux Pane in the Console", .timeLimit(.minutes(1)))
struct TmuxPaneConsoleTests {
    private final class Sink: TerminalByteSink {
        var received = Data()
        func receive(_ data: Data) { received.append(data) }
    }

    private let host = Host(
        address: "mac.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())
    private static let claude = ["claude"]
    /// The same socket's next server, which counts pane ids from zero again.
    private static let next = TmuxServerInstance(
        pid: ScriptedTmuxHost.instance.pid + 1, startTime: ScriptedTmuxHost.instance.startTime + 60)

    private func launch(over tmux: ScriptedTmuxHost) async throws -> ConsoleStore {
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: try defaults()),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths) },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
                    keepalive: KeepalivePolicy(interval: .milliseconds(10)))
            },
            coreHostMemory: HerdrCoreHostMemory(defaults: try defaults()))
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first inventory") { store.hostsAwaitingSnapshot.isEmpty }
        return store
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "tmux-pane-console-\(UUID().uuidString)"))
    }

    private func host(screen: [String] = ["$ claude", "> hello", "", ""]) async -> ScriptedTmuxHost {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(command: "claude", height: 4, arguments: Self.claude)])
        await tmux.setScreen(screen, of: "%0")
        return tmux
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// A store for `%0`, open at the Pane's size, as a detail opens one.
    private func opened(_ runner: @escaping TerminalSessionRunner) -> AttachTerminalStore {
        let store = AttachTerminalStore(target: .terminal("%0"), runTerminal: runner)
        store.viewDidResize(cols: 80, rows: 4)
        return store
    }

    private func text(_ sink: Sink) -> String { String(decoding: sink.received, as: UTF8.self) }

    // MARK: Watching

    @Test func aPaneOpensLiveFromItsFirstPaintThenItsOutput() async throws {
        let tmux = await host()
        let console = try await launch(over: tmux)
        defer { console.setHosts([]) }
        let store = opened(console.terminalRunner(for: host.id, keepingTo: console.corePin(on: host.id)))
        let sink = Sink()
        store.feed.attach(sink)

        try await waitUntil("the first paint") { store.status == .live }
        try await waitUntil("the screen") { text(sink).contains("> hello") }
        await tmux.paneOutput("thinking\r\n", in: "%0")
        try await waitUntil("the Pane's output") { text(sink).hasSuffix("thinking\r\n") }
        #expect(await tmux.openControlClients == 1)

        await store.stop()
        try await waitUntil("the client to go") { await tmux.openControlClients == 0 }
    }

    @Test func aPaneThatIsGoneEndsItsTerminal() async throws {
        let tmux = await host()
        let console = try await launch(over: tmux)
        defer { console.setHosts([]) }
        let store = opened(console.terminalRunner(for: host.id))
        try await waitUntil("the first paint") { store.status == .live }

        await tmux.endUserSessions(holding: "%0")
        try await waitUntil("the end") { store.status == .finished }
        #expect(await tmux.attachSessions.isEmpty)
        #expect(await tmux.controlScripts.count == 1)
    }

    @Test func aDroppedConnectionReattachesOnTheNextOne() async throws {
        let tmux = await host()
        let console = try await launch(over: tmux)
        defer { console.setHosts([]) }
        let store = opened(console.terminalRunner(for: host.id))
        try await waitUntil("the first paint") { store.status == .live }

        await tmux.setScreen(["$ claude", "> again", "", ""], of: "%0")
        await tmux.dropConnections()
        try await waitUntil("the second attach") { await tmux.controlScripts.count == 2 }
        try await waitUntil("its first paint") { store.status == .live }
        #expect(await tmux.openControlClients == 1)
        await store.stop()
    }

    // MARK: Another server (ADR 0042)

    /// The Pane's id came back with another server, as another Pane.
    @Test func aServerReplacedWhileTheConnectionWasDownEndsTheTerminal() async throws {
        let tmux = await host()
        let console = try await launch(over: tmux)
        defer { console.setHosts([]) }
        let pin = console.corePin(on: host.id)
        let store = opened(console.terminalRunner(for: host.id, keepingTo: pin))
        try await waitUntil("the first paint") { store.status == .live }

        await tmux.dropConnections()
        await tmux.startServer(instance: Self.next, panes: [.make(command: "codex", height: 4, arguments: ["codex"])])
        try await waitUntil("the end") { store.status == .finished }
        try await waitUntil("the other server's inventory") { console.hasLeftCore(pin, on: host.id) }
        #expect(await tmux.attachSessions.isEmpty)
        #expect(console.terminalEndedMessage(keepingTo: pin, on: host.id) == TerminalStatusPresentation.tmuxServerGoneMessage)
        await #expect(throws: TransportError.tmuxServerGone) {
            try await console.closePane("%0", on: host.id, keepingTo: pin)
        }
    }

    /// A replacement store for the same screen keeps what the first attach joined.
    @Test func aLaterStoreForTheScreenStaysOnTheServerItFirstJoined() async throws {
        let tmux = await host()
        let console = try await launch(over: tmux)
        defer { console.setHosts([]) }
        let runner = console.terminalRunner(for: host.id)
        let first = opened(runner)
        try await waitUntil("the first paint") { first.status == .live }
        await first.stop()
        try await waitUntil("the client to go") { await tmux.openControlClients == 0 }

        await tmux.startServer(instance: Self.next, panes: [.make(command: "codex", height: 4, arguments: ["codex"])])
        try await waitUntil("the other server") { console.tmuxServer(on: host.id)?.instance == Self.next }
        let replacement = opened(runner)
        try await waitUntil("the replacement sees the end") { replacement.status == .finished }
        #expect(await tmux.controlScripts.count == 1)
    }

    /// A retained Agent terminal (ADR 0017) is another server's Pane once one
    /// took the socket; the detail opened anew gets its own.
    @Test func aRetainedAgentTerminalGivesWayOnceAnotherServerAnswers() async throws {
        let tmux = await host()
        let console = try await launch(over: tmux)
        defer { console.setHosts([]) }
        let cache = console.agentTerminals
        let agent = try #require(console.agents.first)
        let owner = UUID()
        let retained = cache.acquire(agent: agent, console: console, ownerID: owner, corePin: console.corePin(on: host.id))
        retained.attach.viewDidResize(cols: 80, rows: 4)
        try await waitUntil("the first paint") { retained.attach.terminalStatus == .live }
        cache.release(retained, ownerID: owner)

        await tmux.startServer(instance: Self.next, panes: [.make(command: "codex", height: 4, arguments: ["codex"])])
        try await waitUntil("the other server's Agent") { console.agents.first?.agent.kind == "codex" }
        let newAgent = try #require(console.agents.first)
        let reopened = cache.acquire(
            agent: newAgent, console: console, ownerID: UUID(), corePin: console.corePin(on: host.id))
        #expect(reopened !== retained)
        reopened.attach.viewDidResize(cols: 80, rows: 4)
        try await waitUntil("the new server's first paint") { reopened.attach.terminalStatus == .live }
        #expect(await tmux.controlScripts.count == 2)
        try await waitUntil("only its client") { await tmux.openControlClients == 1 }
    }

    /// The detail open on one server's Agent keeps to it, so the row at its
    /// address on the next server is a new pick.
    @Test func anAgentDetailKeepsToTheServerItOpenedOn() async throws {
        let tmux = await host()
        let console = try await launch(over: tmux)
        defer { console.setHosts([]) }
        let agent = try #require(console.agents.first)
        let cores = ConsoleDetailCores()
        let session = cores.session(for: agent, console: console)

        await tmux.startServer(instance: Self.next, panes: [.make(command: "codex", height: 4, arguments: ["codex"])])
        try await waitUntil("the other server's Agent") { console.agents.first?.agent.kind == "codex" }
        #expect(cores.session(for: agent, console: console) === session)
        #expect(cores.listSelection(for: .agent(agent.id), console: console) == .leftBehind(.agent(agent.id)))
        #expect(cores.openAnew(.agent(agent.id), console: console))
        #expect(cores.session(for: agent, console: console) !== session)
    }
}
