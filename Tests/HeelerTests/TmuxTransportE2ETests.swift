import Foundation
import Synchronization
import Testing

@testable import Heeler

/// A tmux Host over real SSH and a real tmux (ADR 0042). The app never starts
/// a server, so each test starts its own through the fixture, on a socket in
/// the fixture account's own tmux directory.
@Suite("tmux real SSH", .enabled(if: RealSSHFixture.gate(TmuxSSHFixture.isConfigured),
    "requires scripts/fixtures/tmux-ssh.py"), .serialized)
struct TmuxTransportE2ETests {
    @Test("connecting and detecting start no server, with a configuration that creates a session on start")
    func neverStartsAServer() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.writeFile(
                at: "\(fixture.configuration.homePath)/.tmux.conf", "new-session -d -s made-by-the-configuration")

            // The login shell resolves the paths, then the stored ones are asked.
            for name in [fixture.socketName, TmuxSocketName.defaultName] {
                let first = try await fixture.read(socketName: name)
                #expect(first.status == .failure(.tmuxServerNotRunning(socketName: name)))
                let resolved = try #require(first.resolved)
                #expect(resolved == (try fixture.paths(name)))
                let stored = try await fixture.read(socketName: name, storedPaths: resolved)
                #expect(stored.status == .failure(.tmuxServerNotRunning(socketName: name)))
            }
            let found = try await fixture.detect()
            #expect(found.tmux == .notRunning(version: fixture.configuration.tmuxVersion))
            #expect(try await fixture.socketFiles().isEmpty)
            #expect(try await fixture.tmuxProcesses().isEmpty)

            // That configuration does create its session, for a client that may
            // start a server: the fixture's own.
            try await fixture.startServer(readingConfiguration: true)
            #expect(try await fixture.sessionNames() == ["made-by-the-configuration", "main"])
            let running = try await fixture.read(storedPaths: try fixture.paths())
            #expect(try running.status.get().instance == (try await fixture.serverInstance()))
            #expect(try await fixture.socketFiles() == [fixture.socketPath()])
        }
    }

    @Test("detection offers tmux with its version and only the sockets a server answers on")
    func detectionOffersAnsweringSockets() async throws {
        try await TmuxSSHFixture.with { fixture in
            let killed = "k" + fixture.socketName.dropFirst()
            try await fixture.startServer()
            try await fixture.startServer(TmuxSocketName.defaultName)
            try await fixture.startServer(killed)
            try await fixture.killServer(killed)
            #expect(try await fixture.exists(fixture.socketPath(killed)))

            let found = try await fixture.detect()
            #expect(
                found.tmux
                    == .running(
                        version: fixture.configuration.tmuxVersion,
                        sockets: [TmuxSocketName.defaultName, fixture.socketName]))
            #expect(found.herdrTUI == .notFound)
            #expect(found.herdrCore == .notInstalled)
            #expect(found.foundKinds == [.tmux])
            #expect(found.offeredKinds == [.tmux])
            // `default` is preselected, and a typed name whose server answers stands.
            #expect(found.preselectedTmuxSocket(typed: "") == TmuxSocketName.defaultName)
            #expect(found.preselectedTmuxSocket(typed: fixture.socketName) == fixture.socketName)
            #expect(found.preselectedTmuxSocket(typed: killed) == TmuxSocketName.defaultName)
            // What a confirmed Host stores comes from this same exec.
            #expect(found.tmuxPaths(socketName: fixture.socketName) == (try fixture.paths()))

            let confirmed = try await fixture.read(storedPaths: found.tmuxPaths(socketName: fixture.socketName))
            #expect(try confirmed.status.get().instance == (try await fixture.serverInstance()))
            #expect(confirmed.resolved == nil)
        }
    }

    @Test("the login shell finds a tmux off the exec's PATH and a socket under its TMUX_TMPDIR")
    func resolvesPathsThroughTheLoginShell() async throws {
        try await TmuxSSHFixture.with { fixture in
            // The exec itself has no tmux, and names another tmux directory.
            #expect(try await fixture.run("command -v tmux").exitStatus != 0)
            let execDirectory = try await fixture.require(#"printf '%s/tmux-%s' "$TMUX_TMPDIR" "$(id -u)""#)
            #expect(execDirectory == fixture.configuration.execSocketDirectory)
            #expect(execDirectory != fixture.configuration.socketDirectory)

            try await fixture.startServer()
            let instance = try await fixture.serverInstance()
            let first = try await fixture.read()
            let status = try first.status.get()
            #expect(status.paths == (try fixture.paths()))
            #expect(status.instance == instance)
            #expect(status.version == fixture.configuration.tmuxVersion)
            #expect(first.resolved == status.paths)

            // Stored, they answer with no login shell in between.
            let stored = try await fixture.read(storedPaths: status.paths)
            #expect(try stored.status.get() == status)
            #expect(stored.resolved == nil)
        }
    }

    @Test("a stored executable that moved is resolved again on the next connection")
    func resolvesAgainAfterTheExecutableMoved() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            // The Host's tmux was somewhere else when it was confirmed.
            let former = "\(fixture.configuration.homePath)/former/bin/tmux"
            try await fixture.require(
                "mkdir -p \(GitProbe.singleQuoted("\(fixture.configuration.homePath)/former/bin")) && ln -s "
                    + "\"$(readlink \(GitProbe.singleQuoted(fixture.configuration.tmuxExecutable)))\" "
                    + GitProbe.singleQuoted(former))
            let storedPaths = try #require(TmuxPaths(executable: former, socket: fixture.socketPath()))
            let before = try await fixture.read(storedPaths: storedPaths)
            #expect(try before.status.get().paths == storedPaths)
            #expect(before.resolved == nil)

            try await fixture.require("rm -rf " + GitProbe.singleQuoted("\(fixture.configuration.homePath)/former"))
            let after = try await fixture.read(storedPaths: storedPaths)
            #expect(try after.status.get().paths == (try fixture.paths()))
            #expect(try after.status.get().instance == (try await fixture.serverInstance()))
            #expect(after.resolved == (try fixture.paths()))

            // The same with no server to find: the new paths are still the ones to keep.
            try await fixture.stopServer()
            let stopped = try await fixture.read(storedPaths: storedPaths)
            #expect(stopped.status == .failure(.tmuxServerNotRunning(socketName: fixture.socketName)))
            #expect(stopped.resolved == (try fixture.paths()))
        }
    }

    @Test("a Host with a server reads connected, and one whose server stopped or was killed reads not running")
    func readsConnectedAndNoServerRunning() async throws {
        try await TmuxSSHFixture.with { fixture in
            let paths = try fixture.paths()
            try await fixture.startServer()
            let first = try await fixture.serverInstance()
            #expect(
                try await fixture.read(storedPaths: paths).status.get()
                    == TmuxServerStatus(instance: first, version: fixture.configuration.tmuxVersion, paths: paths))

            try await fixture.stopServer()
            let notRunning = TransportError.tmuxServerNotRunning(socketName: fixture.socketName)
            #expect(try await fixture.read(storedPaths: paths).status == .failure(notRunning))
            #expect(notRunning.presentation.summary == "No tmux server running")

            // Another run of the server is another instance.
            try await fixture.startServer()
            let second = try await fixture.serverInstance()
            #expect(second != first)
            #expect(try await fixture.read(storedPaths: paths).status.get().instance == second)

            // A killed server's socket file stays, and nothing answers on it.
            try await fixture.killServer()
            #expect(try await fixture.exists(fixture.socketPath()))
            #expect(try await fixture.read(storedPaths: paths).status == .failure(notRunning))
            #expect(try await fixture.read().status == .failure(notRunning))
            #expect(try await fixture.tmuxProcesses().isEmpty)
        }
    }

    @Test("a tmux older than 3.3 reads Update required, naming the version found")
    func readsUpdateRequired() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            try await fixture.withStandInTmux(versionLine: "tmux 3.2a") {
                let read = try await fixture.read()
                #expect(read.status == .failure(.tmuxUpdateRequired(version: "3.2a")))
                #expect(read.resolved == nil)
                #expect(try await fixture.detect().tmux == .updateRequired(version: "3.2a"))

                // Paths stored while the Host's tmux was new enough keep answering:
                // they name that tmux, whatever comes first on PATH now.
                let stored = try await fixture.read(storedPaths: try fixture.paths())
                #expect(try stored.status.get().instance == (try await fixture.serverInstance()))
            }
            let failure = TransportError.tmuxUpdateRequired(version: "3.2a")
            #expect(failure.presentation.summary == "Update required")
            #expect(failure.presentation.detail?.contains("3.2a") == true)
            #expect(!failure.isRetryable)
        }
    }

    @Test("a Host with no tmux reads not installed, and finds it again once it is there")
    func readsNotInstalled() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let paths = try fixture.paths()
            try await fixture.hidingTmux {
                #expect(try await fixture.read().status == .failure(.tmuxNotInstalled))
                let stored = try await fixture.read(storedPaths: paths)
                #expect(stored.status == .failure(.tmuxNotInstalled))
                #expect(stored.resolved == nil)
                #expect(try await fixture.detect().tmux == .notInstalled)
            }
            #expect(!TransportError.tmuxNotInstalled.isRetryable)
            #expect(try await fixture.read(storedPaths: paths).status.get().paths == paths)
        }
    }

    @Test("a Host session waits for a server on the connection it has, then keeps the paths it resolved")
    func aHostSessionWaitsForAServer() async throws {
        try await TmuxSSHFixture.with { fixture in
            let paths = try fixture.paths()
            let dials = Mutex(0)
            let updates = Mutex<[TmuxHostSessionUpdate]>([])
            let pace = Duration.milliseconds(200)
            let session = TmuxHostSession(
                storedPaths: nil,
                connect: { paths in
                    dials.withLock { $0 += 1 }
                    return try await fixture.connectTmux(storedPaths: paths)
                },
                reconnectPolicy: ReconnectPolicy(initialDelay: pace, multiplier: 1, maxDelay: pace),
                keepalive: KeepalivePolicy(interval: pace))
            let reader = Task {
                for await update in session.updates { updates.withLock { $0.append(update) } }
            }
            do {
                await session.resume()
                try await fixture.eventually {
                    updates.withLock { seen in
                        seen.contains { update in
                            guard case .status(.reconnecting(let attempt, _, .tmuxServerNotRunning)) = update else {
                                return false
                            }
                            return attempt >= 2
                        }
                    }
                }
                #expect(updates.withLock { $0.contains(.paths(paths)) })
                #expect(try await fixture.tmuxProcesses().isEmpty)

                try await fixture.startServer()
                let instance = try await fixture.serverInstance()
                let server = TmuxServerStatus(
                    instance: instance, version: fixture.configuration.tmuxVersion, paths: paths)
                try await fixture.eventually { updates.withLock { $0.contains(.server(server)) } }
                #expect(updates.withLock { $0.contains(.status(.connected)) })
                #expect(dials.withLock { $0 } == 1)

                // The server going away is seen on that same connection too.
                try await fixture.stopServer()
                try await fixture.eventually {
                    updates.withLock { seen in
                        guard let connected = seen.lastIndex(of: .status(.connected)) else { return false }
                        return seen[connected...].contains { update in
                            if case .status(.reconnecting(_, _, .tmuxServerNotRunning)) = update { true } else { false }
                        }
                    }
                }
                #expect(dials.withLock { $0 } == 1)
                await session.end()
                await reader.value
            } catch {
                await session.end()
                reader.cancel()
                throw error
            }
        }
    }

    // MARK: Inventory (ADR 0043)

    /// The loop's exec over one connection of the app's own, whose session
    /// slots a test can count.
    private func followed(
        _ fixture: TmuxSSHFixture
    ) async throws -> (ssh: HeelerSSHTransport, transport: TmuxSSHTransport) {
        let paths = try fixture.paths()
        let ssh = try await HeelerSSHTransport.connect(settings: try fixture.settings(storedPaths: paths))
        return (ssh, TmuxSSHTransport(connection: ssh, socketName: fixture.socketName, storedPaths: paths))
    }

    /// What a loop printed so far, and whether its stream ended.
    private final class Followed: Sendable {
        private let state = Mutex<(inventories: [TmuxInventory], ended: Bool, failure: String?)>(([], false, nil))
        var inventories: [TmuxInventory] { state.withLock { $0.inventories } }
        var count: Int { state.withLock { $0.inventories.count } }
        var last: TmuxInventory? { state.withLock { $0.inventories.last } }
        var ended: Bool { state.withLock { $0.ended } }
        var failure: String? { state.withLock { $0.failure } }

        /// Waits for the loop to print what `predicate` looks for, and says what
        /// it printed last where it never does.
        func eventually(
            _ fixture: TmuxSSHFixture, _ predicate: @Sendable (Followed) -> Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            do {
                try await fixture.eventually { predicate(self) }
            } catch TmuxSSHFailure.timeout {
                Issue.record(
                    "The loop printed \(count) inventories, ended: \(ended), failure: \(failure ?? "none"), last: \(String(describing: last))",
                    sourceLocation: sourceLocation)
                throw TmuxSSHFailure.timeout
            }
        }

        func follow(_ stream: AsyncThrowingStream<TmuxInventory, any Error>) -> Task<Void, Never> {
            Task {
                do {
                    for try await inventory in stream { state.withLock { $0.inventories.append(inventory) } }
                } catch {
                    state.withLock { $0.failure = "\(error)" }
                }
                state.withLock { $0.ended = true }
            }
        }
    }

    @Test("the inventory loop prints once and then only on change, in one ordinary SSH session")
    func theInventoryLoopPrintsOnceAndThenOnlyOnChange() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            // A name of its own, so tmux does not rename the window after its program.
            try await fixture.tmux(nil, "rename-window", "-t", "main:0", "first")
            let instance = try await fixture.serverInstance()
            let (ssh, transport) = try await followed(fixture)
            do {
                _ = try await transport.status()
                #expect(await ssh.ordinarySessionChannelCountForTesting() == 0)
                let loop = Followed()
                let reading = loop.follow(try await transport.inventory())
                try await loop.eventually(fixture) { $0.count == 1 }
                let first = try #require(loop.last)
                #expect(first.instance == instance)
                #expect(first.panes.map(\.paneID) == ["%0"])
                #expect(first.panes.map(\.sessionName) == ["main"])
                #expect(first.panes.map(\.windowName) == ["first"])
                #expect(first.panes.map(\.width) == [80])
                #expect(first.panes.map(\.height) == [24])
                #expect(first.panes.map(\.isDead) == [false])
                // The loop is one of the connection's four ordinary sessions.
                #expect(await ssh.ordinarySessionChannelCountForTesting() == 1)

                // It asks every second, and says nothing while nothing changed.
                try await Task.sleep(for: .milliseconds(2500))
                #expect(loop.count == 1)

                // Two words, which tmux runs itself: the account's shell is not in between.
                try await fixture.tmux(nil, "new-window", "-d", "-t", "main:", "-n", "build", "/bin/cat", "-u")
                try await loop.eventually(fixture) {
                    $0.last?.panes.map(\.windowName) == ["first", "build"] && $0.last?.panes.last?.command == "cat"
                }
                // A new pane comes with what its foreground program was started as.
                #expect(loop.last?.panes.last?.foregroundArguments == ["/bin/cat", "-u"])
                #expect(loop.last?.panes.map(\.paneID) == ["%0", "%1"])
                #expect(loop.last?.panes.map(\.windowIndex) == [0, 1])
                let afterTheWindow = loop.count
                try await Task.sleep(for: .milliseconds(2200))
                #expect(loop.count == afterTheWindow)

                try await fixture.tmux(nil, "rename-window", "-t", "main:1", "release")
                try await loop.eventually(fixture) { $0.last?.panes.map(\.windowName) == ["first", "release"] }
                #expect(loop.count == afterTheWindow + 1)
                // Its one-shot asks ran beside the loop, on the same connection.
                #expect(try await transport.status().instance == instance)

                // Letting go of the loop ends its exec and frees its session.
                reading.cancel()
                await reading.value
                try await fixture.eventually { await ssh.ordinarySessionChannelCountForTesting() == 0 }
                #expect(try await fixture.answers())

                // Another loop starts from everything again, and ends with its server.
                let second = Followed()
                let secondReading = second.follow(try await transport.inventory())
                try await second.eventually(fixture) { $0.count == 1 }
                #expect(second.last?.panes.map(\.windowName) == ["first", "release"])
                try await fixture.stopServer()
                try await second.eventually(fixture) { $0.ended }
                await secondReading.value
                #expect(second.failure == nil)
                #expect(second.count == 1)
                try await fixture.eventually { await ssh.ordinarySessionChannelCountForTesting() == 0 }
                await #expect(throws: TransportError.tmuxServerNotRunning(socketName: fixture.socketName)) {
                    try await transport.status()
                }
                try await transport.close()
            } catch {
                try? await transport.close()
                throw error
            }
        }
    }

    /// A Console over the fixture, on a device of its own.
    @MainActor
    private func console(over fixture: TmuxSSHFixture, on defaults: UserDefaults) throws -> (ConsoleStore, Host) {
        let pace = Duration.milliseconds(200)
        let host = Host(
            address: fixture.configuration.host, port: Int(fixture.configuration.port),
            username: fixture.configuration.username, serverKind: .tmux, sessionName: fixture.socketName,
            tmuxPaths: try fixture.paths())
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in try await fixture.connectTmux(storedPaths: paths) },
                    reconnectPolicy: ReconnectPolicy(initialDelay: pace, multiplier: 1, maxDelay: pace),
                    keepalive: KeepalivePolicy(interval: pace))
            },
            coreHostMemory: HerdrCoreHostMemory(defaults: defaults))
        return (store, host)
    }

    /// A program whose arguments name a known agent: `cat` under that name.
    private func agentProgram(_ name: String, on fixture: TmuxSSHFixture) async throws -> String {
        let directory = "\(fixture.configuration.homePath)/agents"
        let program = "\(directory)/\(name)"
        try await fixture.require(
            "mkdir -p \(GitProbe.singleQuoted(directory)) && ln -sf /bin/cat \(GitProbe.singleQuoted(program))")
        return program
    }

    @Test("a new window, a rename and an agent's program reach the Console")
    func aNewWindowAndARenameReachTheConsole() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            try await fixture.tmux(nil, "rename-window", "-t", "main:0", "first")
            let claude = try await agentProgram("claude", on: fixture)
            try await reachTheConsole(fixture, claude: claude)
        }
    }

    @MainActor
    private func reachTheConsole(_ fixture: TmuxSSHFixture, claude: String) async throws {
        let suite = "tmux-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, host) = try console(over: fixture, on: defaults)
        store.setHosts([host])
        await store.resume()
        do {
            try await fixture.eventually { await store.terminals.map(\.paneID) == ["%0"] }
            #expect(store.hostStatuses[host.id] == .connected)
            #expect(store.terminals.map(\.workspaceLabel) == ["main"])
            #expect(store.terminals.map(\.tabLabel) == ["first"])
            #expect(store.agents.isEmpty)

            // A new window, within about a second.
            try await fixture.tmux(nil, "new-window", "-d", "-t", "main:", "-n", "agent", claude, "-u")
            try await fixture.eventually { await store.terminals.map(\.tabLabel) == ["first", "agent"] }
            #expect(store.terminals.map(\.paneID) == ["%0", "%1"])
            #expect(store.terminals.map(\.workspaceID) == ["$0", "$0"])
            // Its program is a known agent's, and a plain `cat` is a terminal.
            try await fixture.eventually { await store.agents.map(\.agent.paneID) == ["%1"] }
            #expect(store.agents.first?.agent.kind == "claude")
            #expect(store.agents.first?.agent.status == .unknown)

            // A rename of the window, then of the session.
            try await fixture.tmux(nil, "rename-window", "-t", "main:1", "review")
            try await fixture.eventually { await store.terminals.map(\.tabLabel) == ["first", "review"] }
            try await fixture.tmux(nil, "rename-session", "-t", "main", "work")
            try await fixture.eventually { await store.terminals.map(\.workspaceLabel) == ["work", "work"] }
            #expect(store.workspacesByHost[host.id]?.map(\.label) == ["work"])

            // A window closed takes its Agent with it.
            try await fixture.tmux(nil, "kill-window", "-t", "work:1")
            try await fixture.eventually { await store.terminals.map(\.paneID) == ["%0"] }
            #expect(store.agents.isEmpty)
            store.setHosts([])
        } catch {
            store.setHosts([])
            throw error
        }
    }

    @Test("a restarted server reads as a new instance where its pane ids repeat, and drops the old one's Pins")
    func aRestartedServerReadsAsANewInstance() async throws {
        try await TmuxSSHFixture.with { fixture in
            let codex = try await agentProgram("codex", on: fixture)
            try await restartUnderTheConsole(fixture, codex: codex)
        }
    }

    @MainActor
    private func restartUnderTheConsole(_ fixture: TmuxSSHFixture, codex: String) async throws {
        let suite = "tmux-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let agentWindow = ["new-window", "-d", "-t", "main:", "-n", "agent", codex, "-u"]
        let (store, host) = try console(over: fixture, on: defaults)
        do {
            try await fixture.startServer()
            let first = try await fixture.serverInstance()
            try await fixture.require(fixture.tmuxLine(agentWindow))
            store.setHosts([host])
            await store.resume()
            try await fixture.eventually { await store.agents.map(\.agent.paneID) == ["%1"] }
            #expect(store.tmuxServer(on: host.id)?.instance == first)
            let pin = store.corePin(on: host.id)
            #expect(pin.admits(first.id))
            store.togglePin(hostID: host.id, paneID: "%1")
            #expect(PinnedAgentsStore(defaults: defaults).pinnedPaneIDs(for: host.id) == ["%1"])

            // The server stops: nothing says what became of its Panes.
            try await fixture.stopServer()
            try await fixture.eventually {
                if case .reconnecting(_, _, .tmuxServerNotRunning) = await store.hostStatuses[host.id] { true } else { false }
            }
            #expect(store.terminals.isEmpty)
            #expect(PinnedAgentsStore(defaults: defaults).pinnedPaneIDs(for: host.id) == ["%1"])

            // Another run of it counts its panes from `%0` again.
            try await fixture.startServer()
            let second = try await fixture.serverInstance()
            #expect(second != first)
            try await fixture.require(fixture.tmuxLine(agentWindow))
            try await fixture.eventually { await store.agents.map(\.agent.paneID) == ["%1"] }
            #expect(store.terminals.map(\.paneID) == ["%0", "%1"])
            #expect(store.tmuxServer(on: host.id)?.instance == second)
            // The same pane id is another Pane: its Pin is gone, and a detail
            // opened on the first instance has left it.
            #expect(store.pins.pinnedPaneIDs(for: host.id).isEmpty)
            #expect(PinnedAgentsStore(defaults: defaults).pinnedPaneIDs(for: host.id).isEmpty)
            #expect(store.hasLeftCore(pin, on: host.id))
            #expect(HerdrCoreHostMemory(defaults: defaults).coreID(for: host.id) == second.id)
            store.setHosts([])
        } catch {
            store.setHosts([])
            throw error
        }
    }
}
