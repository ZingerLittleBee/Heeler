import Foundation
import Synchronization
import Testing

@testable import Heeler

/// A tmux Host over real SSH and a real tmux (ADR 0042). Connecting never
/// starts a server, so a test starts its own through the fixture, on a socket
/// in the fixture account's own tmux directory. The one launch that starts a
/// server is Linux New Workspace, and only that test lets it.
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
    func console(over fixture: TmuxSSHFixture, on defaults: UserDefaults) throws -> (ConsoleStore, Host) {
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

    @Test("a variable set in the global and session environment is found by name")
    func aVariableSetInTheGlobalAndSessionEnvironmentIsFoundByName() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let session = trimmed(
                try await fixture.tmux(nil, "display-message", "-p", "-t", "main", "#{session_id}"))
            // Values stay on the Host. These strings are the fixture's own, and
            // the published notice must not contain them.
            let claudeValue = "/fixture/claude-token"
            let threadValue = "/fixture/codex-thread"
            try await fixture.tmux(nil, "set-environment", "-g", "CLAUDECODE", claudeValue)
            try await fixture.tmux(nil, "set-environment", "-t", session, "CODEX_THREAD_ID", threadValue)
            try await environmentReachesTheConsole(
                fixture, claudeValue: claudeValue, threadValue: threadValue)
        }
    }

    /// The server may already carry other names, so this checks the planted
    /// leaked names are present. Values stay on the Host.
    @MainActor
    private func environmentReachesTheConsole(
        _ fixture: TmuxSSHFixture, claudeValue: String, threadValue: String
    ) async throws {
        try await withConsole(fixture) { store, host in
            try await fixture.eventually {
                let names = await store.hostCoreEnvironmentNotices[host.id]?.variables.map(\.name) ?? []
                return names.contains("CLAUDECODE") && names.contains("CODEX_THREAD_ID")
            }
            let notice = try #require(store.hostCoreEnvironmentNotices[host.id])
            let expected = try #require(HerdrCoreEnvironmentNotice(names: ["CLAUDECODE"]))
            let variable = try #require(notice.variables.first { $0.name == "CLAUDECODE" })
            #expect(variable == expected.variables[0])
            #expect(notice.variables.contains { $0.name == "CODEX_THREAD_ID" })
            let published = (notice.variables.map(\.name) + notice.variables.map(\.breaks)).joined(separator: "\n")
            #expect(!published.contains(claudeValue))
            #expect(!published.contains(threadValue))
            #expect(!published.contains("/fixture"))
        }
    }

    // MARK: Launches

    /// `claude` on the login shell's PATH, the program a New Agent asks for.
    /// `cat` exits on `--session-id`, so the stand-in is a script that stays the
    /// pane's foreground until it is killed, and takes its `sleep` with it.
    private func agentOnLoginPath(on fixture: TmuxSSHFixture) async throws {
        let program = "\(fixture.configuration.firstDirectory)/claude"
        try await fixture.writeProgram(
            at: program,
            """
            #!/bin/sh
            trap 'kill "$child" 2>/dev/null; exit 0' TERM INT HUP
            sleep 3600 &
            child=$!
            wait
            """)
    }

    /// A directory that exists, which `new-window -c` and `new-session -c` require.
    private func workDirectory(on fixture: TmuxSSHFixture) async throws -> String {
        let path = "\(fixture.configuration.homePath)/work"
        try await fixture.require("mkdir -p \(GitProbe.singleQuoted(path))")
        return path
    }

    private func currentWindow(_ session: String, on fixture: TmuxSSHFixture) async throws -> String {
        trimmed(try await fixture.tmux(nil, "display-message", "-p", "-t", session, "#{window_id}"))
    }

    private func paneField(
        _ format: String, of target: String, on fixture: TmuxSSHFixture
    ) async throws -> String {
        trimmed(try await fixture.tmux(nil, "display-message", "-p", "-t", target, format))
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sidebar sorts by label. `order` is the order tmux listed the sessions.
    @MainActor
    private func labelsInListOrder(_ store: ConsoleStore, host: Host) -> [String] {
        (store.workspacesByHost[host.id] ?? []).sorted { $0.order < $1.order }.map(\.label)
    }

    /// Session names in the order `list-panes -a` prints them. A session tmux
    /// just created is listed before the one that was already current.
    private func sessionLabelsInListOrder(on fixture: TmuxSSHFixture) async throws -> [String] {
        let text = try await fixture.tmux(nil, "list-panes", "-a", "-F", "#{session_name}")
        var labels: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let label = String(line)
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        return labels
    }

    /// Where a `uname` that prints `Linux` is first on the exec's PATH.
    private func linuxUnamePath(_ fixture: TmuxSSHFixture) -> String {
        let root = URL(fileURLWithPath: fixture.configuration.homePath).deletingLastPathComponent().path
        return "\(root)/bin/uname"
    }

    private func loginTmpDir(_ fixture: TmuxSSHFixture) -> String {
        URL(fileURLWithPath: fixture.configuration.socketDirectory).deletingLastPathComponent().path
    }

    @MainActor
    private func withConsole(
        _ fixture: TmuxSSHFixture, _ body: (ConsoleStore, Host) async throws -> Void
    ) async throws {
        let suite = "tmux-e2e-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, host) = try console(over: fixture, on: defaults)
        store.setHosts([host])
        await store.resume()
        do {
            try await body(store, host)
            store.setHosts([])
        } catch {
            store.setHosts([])
            throw error
        }
    }

    @Test("a new agent opens a detached window and the window ends when the agent exits")
    func aNewAgentLeavesTheCurrentWindowAndEndsWhenItExits() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            try await agentOnLoginPath(on: fixture)
            let directory = try await workDirectory(on: fixture)
            try await launchAgent(fixture, directory: directory)
        }
    }

    @MainActor
    private func launchAgent(_ fixture: TmuxSSHFixture, directory: String) async throws {
        try await withConsole(fixture) { store, host in
            try await fixture.eventually { await store.workspacesByHost[host.id]?.map(\.label) == ["main"] }
            let session = try #require(store.workspacesByHost[host.id]?.first?.id)
            let current = try await currentWindow(session, on: fixture)

            let opened = try await store.startAgent(
                AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: session, cwd: directory),
                on: host.id)

            #expect(opened.workspaceID == session)
            #expect(opened.tabID != current)
            #expect(try await currentWindow(session, on: fixture) == current)
            try await fixture.eventually {
                let pid = try await self.paneField("#{pane_pid}", of: opened.paneID, on: fixture)
                let response = try await fixture.run("ps -ww -o args= -p \(pid)")
                guard response.exitStatus == 0 else { return false }
                let line = String(decoding: response.stdout, as: UTF8.self)
                return line.contains("claude") && line.contains("--session-id") && line.contains("--settings")
            }
            try await expectClaudeCodeHooksPlaced(fixture, paths: try #require(store.tmuxServer(on: host.id)?.paths))
            try await expectHostDetailAddsAndRemovesTheHooks(store.claudeCodeHooksFlow(on: host.id), on: fixture)
            let reported = try await paneField("#{pane_current_path}", of: opened.paneID, on: fixture)
            let physical = trimmed(
                try await fixture.require("cd \(GitProbe.singleQuoted(directory)) && pwd -P"))
            #expect(reported == directory || reported == physical)
            try await fixture.eventually { await store.agents.contains { $0.agent.paneID == opened.paneID } }
            #expect(try await currentWindow(session, on: fixture) == current)

            let pid = try await paneField("#{pane_pid}", of: opened.paneID, on: fixture)
            try await fixture.require("kill \(pid)")
            try await fixture.eventually {
                let windows = try await fixture.tmux(nil, "list-windows", "-t", session, "-F", "#{window_id}")
                return !windows.contains(opened.tabID) && windows.contains(current)
            }
            #expect(try await currentWindow(session, on: fixture) == current)
            try await fixture.eventually { await store.agents.isEmpty }
            #expect(await store.terminals.contains { $0.paneID == "%0" })
        }
    }

    /// Heeler's hook script, and the stored tmux paths it runs, where the
    /// Helper's own script finds the Host's data home (ADR 0044).
    private func expectClaudeCodeHooksPlaced(_ fixture: TmuxSSHFixture, paths: TmuxPaths) async throws {
        let located = try await fixture.run(String(decoding: TmuxClaudeCodeHooks.locateScript(nonce: "e2e"), as: UTF8.self))
        let data = try TmuxClaudeCodeHooks.locations(stdout: located.stdout, nonce: "e2e").dataHome
        let script = try await fixture.run("cat \(GitProbe.singleQuoted(ClaudeCodeHooks.scriptPath(dataHome: data)))")
        #expect(script.stdout == (try TmuxClaudeCodeHooks.bundledScript()))
        let stored = try await fixture.run(
            "cat \(GitProbe.singleQuoted(TmuxClaudeCodeHooks.storedPathsFile(dataHome: data, paths: paths)))")
        #expect(try JSONDecoder().decode(TmuxPaths.self, from: stored.stdout) == paths)
    }

    /// Host detail adds the hooks to the default root, which is under the
    /// fixture's own HOME, and takes them out again, leaving the file as it was.
    @MainActor
    private func expectHostDetailAddsAndRemovesTheHooks(
        _ flow: ClaudeCodeHooksFlow, on fixture: TmuxSSHFixture
    ) async throws {
        await flow.load()
        let root = try #require(flow.roots.first { $0.accountName == nil })
        let home = URL(fileURLWithPath: fixture.configuration.homePath).resolvingSymlinksInPath().path
        let rootHome = URL(fileURLWithPath: root.path).deletingLastPathComponent().resolvingSymlinksInPath().path
        try #require(rootHome == home, "\(root.path) is not under the fixture's HOME")
        let folder = GitProbe.singleQuoted(root.path)
        let settings = GitProbe.singleQuoted(root.settingsPath)
        let original = Data("{\n  \"model\": \"opus\"\n}\n".utf8)
        try await fixture.require("mkdir \(folder) && printf '{\\n  \"model\": \"opus\"\\n}\\n' > \(settings)")
        #expect(try await fixture.run("cat \(settings)").stdout == original)

        await flow.dismiss(root)
        await flow.review(root, adding: true)
        if case .review(let change, adding: true) = flow.states[root.id] {
            await flow.accept(root)
            #expect(flow.states[root.id] == .read(.on))
            #expect(try await fixture.run("cat \(settings)").stdout == change.after)
            await flow.review(root, adding: false)
            await flow.accept(root)
            #expect(flow.states[root.id] == .read(.off))
            #expect(try await fixture.run("cat \(settings)").stdout == original)
        } else {
            Issue.record("expected a review, got \(String(describing: flow.states[root.id]))")
        }
        try await fixture.require("rm -rf \(folder)")
    }

    @Test("a new terminal opens a window running the user's shell")
    func aNewTerminalOpensTheUsersShell() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let directory = try await workDirectory(on: fixture)
            let shell = trimmed(try await fixture.tmux(nil, "show-options", "-g", "default-shell"))
            let name = String(shell.split(separator: " ").last?.split(separator: "/").last ?? "")
            try await launchTerminal(fixture, directory: directory, shell: name)
        }
    }

    @MainActor
    private func launchTerminal(
        _ fixture: TmuxSSHFixture, directory: String, shell: String
    ) async throws {
        try await withConsole(fixture) { store, host in
            try await fixture.eventually { await store.terminals.contains { $0.paneID == "%0" } }
            let session = try #require(store.workspacesByHost[host.id]?.first?.id)
            let current = try await currentWindow(session, on: fixture)

            let opened = try await store.createShellTerminal(
                ShellTerminalCreationRequest(workspaceID: session, cwd: directory), on: host.id)

            #expect(opened.tabID != current)
            #expect(try await currentWindow(session, on: fixture) == current)
            try await fixture.eventually {
                await store.terminals.contains { $0.paneID == opened.paneID && $0.pane.title == shell }
            }
            let terminal = try #require(store.terminals.first { $0.paneID == opened.paneID })
            #expect(terminal.snapshotAgentKind == nil)
            #expect(await store.agents.contains { $0.agent.paneID == opened.paneID } == false)
            let reported = try await paneField("#{pane_current_path}", of: opened.paneID, on: fixture)
            let physical = trimmed(
                try await fixture.require("cd \(GitProbe.singleQuoted(directory)) && pwd -P"))
            #expect(reported == directory || reported == physical)
            #expect(try await currentWindow(session, on: fixture) == current)
            #expect(await store.terminals.contains { $0.paneID == "%0" })
        }
    }

    @Test("a new workspace is a session, named as typed or numbered by tmux")
    func aNewWorkspaceUsesTheTypedNameOrTmuxNumbering() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            let directory = try await workDirectory(on: fixture)
            try await launchWorkspaces(fixture, directory: directory)
        }
    }

    @MainActor
    private func launchWorkspaces(_ fixture: TmuxSSHFixture, directory: String) async throws {
        try await withConsole(fixture) { store, host in
            try await fixture.eventually { await self.labelsInListOrder(store, host: host) == ["main"] }
            let current = try await currentWindow("main", on: fixture)

            _ = try await store.createShellWorkspace(
                NewWorkspaceSpec(directory: directory, label: ""), tabLabel: nil, on: host.id)
            try await fixture.eventually {
                let listed = try await self.sessionLabelsInListOrder(on: fixture)
                return await self.labelsInListOrder(store, host: host) == listed && listed.count == 2
            }
            #expect(try await currentWindow("main", on: fixture) == current)
            #expect(try await fixture.sessionNames() == ["1", "main"])

            _ = try await store.createShellWorkspace(
                NewWorkspaceSpec(directory: directory, label: "feature"), tabLabel: nil, on: host.id)
            try await fixture.eventually {
                let listed = try await self.sessionLabelsInListOrder(on: fixture)
                return await self.labelsInListOrder(store, host: host) == listed && listed.count == 3
            }
            #expect(try await fixture.sessionNames() == ["1", "feature", "main"])
            #expect(try await currentWindow("main", on: fixture) == current)
            let feature = try await currentWindow("feature", on: fixture)
            #expect(feature != current)
        }
    }

    @Test("linux with no server starts one through the login shell")
    func linuxStartsAServerThroughTheLoginShell() async throws {
        try await TmuxSSHFixture.with { fixture in
            let uname = linuxUnamePath(fixture)
            let quoted = GitProbe.singleQuoted(uname)
            try await fixture.writeProgram(at: uname, "#!/bin/sh\nprintf 'Linux\\n'")
            do {
                let directory = try await workDirectory(on: fixture)
                try await launchOnLinux(fixture, directory: directory)
                _ = try await fixture.run("rm -f \(quoted)")
            } catch {
                _ = try? await fixture.run("rm -f \(quoted)")
                throw error
            }
        }
    }

    @MainActor
    private func launchOnLinux(_ fixture: TmuxSSHFixture, directory: String) async throws {
        try await withConsole(fixture) { store, host in
            try await fixture.eventually {
                if case .reconnecting(_, _, .tmuxServerNotRunning) = await store.hostStatuses[host.id] { true } else { false }
            }
            _ = try await store.createShellWorkspace(
                NewWorkspaceSpec(directory: directory, label: "started"), tabLabel: nil, on: host.id)

            // `-N` would not start a server, and the exec's own directory would
            // show if the login shell had not wrapped the start.
            let environment = trimmed(try await fixture.tmux(nil, "show-environment", "-g", "TMUX_TMPDIR"))
            #expect(environment == "TMUX_TMPDIR=\(self.loginTmpDir(fixture))")
            let execTmp = URL(fileURLWithPath: fixture.configuration.execSocketDirectory)
                .deletingLastPathComponent().path
            #expect(environment != "TMUX_TMPDIR=\(execTmp)")
            try await fixture.eventually { await self.labelsInListOrder(store, host: host) == ["started"] }
            #expect(store.hostStatuses[host.id] == .connected)
        }
    }

    @Test("macos with no server says to start tmux on the Mac and starts nothing")
    func macosSaysToStartTmuxOnTheMac() async throws {
        try await TmuxSSHFixture.with { fixture in
            let directory = try await workDirectory(on: fixture)
            try await refuseOnMac(fixture, directory: directory)
        }
    }

    @MainActor
    private func refuseOnMac(_ fixture: TmuxSSHFixture, directory: String) async throws {
        try await withConsole(fixture) { store, host in
            try await fixture.eventually {
                if case .reconnecting(_, _, .tmuxServerNotRunning) = await store.hostStatuses[host.id] { true } else { false }
            }
            await #expect(throws: TransportError.tmuxStartOnMac) {
                try await store.createShellWorkspace(
                    NewWorkspaceSpec(directory: directory), tabLabel: nil, on: host.id)
            }
            #expect(try await fixture.answers() == false)
            #expect(try await fixture.socketFiles().contains(fixture.socketPath()) == false)
        }
    }

    @Test("rename and close reach the session, the window and the pane")
    func renameAndCloseEndWhatTheyName() async throws {
        try await TmuxSSHFixture.with { fixture in
            try await fixture.startServer()
            try await agentOnLoginPath(on: fixture)
            let directory = try await workDirectory(on: fixture)
            let claude = try await agentProgram("claude", on: fixture)
            try await renameAndClose(fixture, directory: directory, claude: claude)
        }
    }

    @MainActor
    private func renameAndClose(
        _ fixture: TmuxSSHFixture, directory: String, claude: String
    ) async throws {
        try await withConsole(fixture) { store, host in
            try await fixture.eventually { await self.labelsInListOrder(store, host: host) == ["main"] }
            let session = try #require(store.workspacesByHost[host.id]?.first?.id)
            let current = try await currentWindow(session, on: fixture)

            try await store.renameWorkspace(session, label: "renamed", on: host.id)
            try await fixture.eventually { await self.labelsInListOrder(store, host: host) == ["renamed"] }
            #expect(try await fixture.sessionNames() == ["renamed"])
            #expect(try await currentWindow(session, on: fixture) == current)

            let opened = try await store.startAgent(
                AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: session, cwd: directory),
                on: host.id)
            try await fixture.eventually { await store.agents.contains { $0.agent.paneID == opened.paneID } }
            let agent = try #require(store.agents.first { $0.agent.paneID == opened.paneID })
            try await store.closeAgent(agent)
            try await fixture.eventually {
                let windows = try await fixture.tmux(nil, "list-windows", "-t", session, "-F", "#{window_id}")
                return windows.contains(current) && !windows.contains(opened.tabID)
            }
            try await fixture.eventually { await store.agents.isEmpty }

            try await fixture.tmux(nil, "split-window", "-d", "-t", session, claude, "-u")
            try await fixture.eventually { await store.agents.count == 1 }
            let shared = try #require(store.agents.first)
            let pane = shared.agent.paneID
            #expect(pane != "%0")
            #expect(shared.tabPaneCount > 1)
            try await store.closeAgent(shared)
            try await fixture.eventually {
                let panes = try await fixture.tmux(nil, "list-panes", "-t", session, "-F", "#{pane_id}")
                return panes.contains("%0") && !panes.contains(pane)
            }
            #expect(try await currentWindow(session, on: fixture) == current)
            try await fixture.eventually { await self.labelsInListOrder(store, host: host) == ["renamed"] }
            try await fixture.eventually { await store.agents.isEmpty }
        }
    }
}
