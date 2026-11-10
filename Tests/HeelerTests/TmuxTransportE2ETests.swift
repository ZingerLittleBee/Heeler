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
}
