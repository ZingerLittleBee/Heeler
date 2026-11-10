import Foundation
import Testing

@testable import Heeler

@Suite("tmux SSH transport")
struct TmuxSSHTransportTests {
    private let stored = ScriptedTmuxHost.paths()

    @Test func storedPathsThatAnswerNeedNoLoginShell() async throws {
        let host = ScriptedTmuxHost()
        let transport = await host.transport(socketName: "default", storedPaths: stored)

        let status = try await transport.status()

        #expect(status == TmuxServerStatus(instance: ScriptedTmuxHost.instance, version: "3.7b", paths: stored))
        #expect(await host.log == ["probe stored"])
        #expect(await transport.resolvedPaths() == nil)
        let script = try #require(await host.scripts.first)
        #expect(script.contains("t='/opt/homebrew/bin/tmux'"))
        #expect(script.contains("s='/private/tmp/tmux-501/default'"))
        #expect(!script.contains("-lic"))
    }

    @Test func aHostWithNoStoredPathsResolvesThemThroughTheLoginShell() async throws {
        let host = ScriptedTmuxHost(sockets: ["work"])
        let transport = await host.transport(socketName: " work ", storedPaths: nil)

        let status = try await transport.status()

        let paths = ScriptedTmuxHost.paths("work")
        #expect(status.paths == paths)
        #expect(await transport.resolvedPaths() == paths)
        #expect(await host.log == ["probe login"])
        #expect(try #require(await host.scripts.first).contains("n='\\''work'\\''"))

        // From then on the resolved paths are asked, with no startup file in between.
        await host.clearLog()
        _ = try await transport.status()
        #expect(await host.log == ["probe stored"])
    }

    @Test func aBlankSocketNameIsTheDefaultSocket() async throws {
        let host = ScriptedTmuxHost()
        let transport = await host.transport(socketName: "", storedPaths: nil)

        #expect(try await transport.status().paths == stored)
    }

    /// The acceptance case: the stored executable moved, and the next
    /// connection finds the new one through the login shell.
    @Test func aStoredExecutableThatMovedIsResolvedAgain() async throws {
        let host = ScriptedTmuxHost()
        await host.moveExecutable(to: "/usr/local/bin/tmux")
        let transport = await host.transport(socketName: "default", storedPaths: stored)

        let status = try await transport.status()

        let moved = try #require(TmuxPaths(executable: "/usr/local/bin/tmux", socket: stored.socket))
        #expect(status.paths == moved)
        #expect(status.instance == ScriptedTmuxHost.instance)
        #expect(await transport.resolvedPaths() == moved)
        #expect(await host.log == ["probe stored", "probe login"])

        await host.clearLog()
        _ = try await transport.status()
        #expect(await host.log == ["probe stored"])
        #expect(try #require(await host.scripts.first).contains("t='/usr/local/bin/tmux'"))
    }

    /// The login shell's files now name another tmux directory.
    @Test func aStoredSocketThatMovedIsResolvedAgain() async throws {
        let host = ScriptedTmuxHost()
        await host.moveDirectory(to: "/Users/dev/run/tmux-501")
        let transport = await host.transport(socketName: "default", storedPaths: stored)

        let status = try await transport.status()

        #expect(status.paths.socket == "/Users/dev/run/tmux-501/default")
        #expect(await transport.resolvedPaths() == status.paths)
    }

    @Test func pathsStoredForAnotherSocketNameAreNotAsked() async throws {
        let host = ScriptedTmuxHost(sockets: ["default", "work"])
        let transport = await host.transport(socketName: "work", storedPaths: stored)

        let status = try await transport.status()

        #expect(status.paths == ScriptedTmuxHost.paths("work"))
        #expect(await host.log == ["probe login"])
    }

    @Test func noServerRunningIsItsOwnFailureAndStartsNone() async throws {
        let host = ScriptedTmuxHost(sockets: [])
        let transport = await host.transport(socketName: "default", storedPaths: stored)

        await #expect(throws: TransportError.tmuxServerNotRunning(socketName: "default")) {
            try await transport.status()
        }

        #expect(await host.log == ["probe stored", "probe login"])
        // The paths were right all along, so there is nothing new to store.
        #expect(await transport.resolvedPaths() == nil)
        for script in await host.scripts {
            #expect(!script.contains("new-session"))
            #expect(!script.contains("start-server"))
            let commands = script.split(separator: "\n").filter { $0.contains("display-message") }
            #expect(commands.allSatisfy { $0.contains("-N -S") })
        }
    }

    /// A Host whose server is not running is asked again and again. Its login
    /// shell's startup files run once, not on every ask.
    @Test func aStoppedServerIsPolledWithoutTheLoginShell() async throws {
        let host = ScriptedTmuxHost(sockets: [])
        let transport = await host.transport(socketName: "default", storedPaths: stored)
        await #expect(throws: TransportError.tmuxServerNotRunning(socketName: "default")) {
            try await transport.status()
        }
        await host.clearLog()

        for _ in 0..<3 {
            await #expect(throws: TransportError.tmuxServerNotRunning(socketName: "default")) {
                try await transport.status()
            }
        }
        #expect(await host.log == ["probe stored", "probe stored", "probe stored"])

        // The user starts tmux: the same paths answer.
        await host.startServer()
        await host.clearLog()
        #expect(try await transport.status().instance == ScriptedTmuxHost.instance)
        #expect(await host.log == ["probe stored"])

        // It stops again: that is news, so the login shell is asked once more.
        await host.stopServer()
        await host.clearLog()
        await #expect(throws: TransportError.tmuxServerNotRunning(socketName: "default")) {
            try await transport.status()
        }
        #expect(await host.log == ["probe stored", "probe login"])
    }

    @Test func aTmuxThatMovedWhileItsServerWasStoppedIsLookedUpAgain() async throws {
        let host = ScriptedTmuxHost(sockets: [])
        let transport = await host.transport(socketName: "default", storedPaths: stored)
        await #expect(throws: TransportError.tmuxServerNotRunning(socketName: "default")) {
            try await transport.status()
        }

        // An upgrade moves the tmux, and the user starts it from there.
        await host.moveExecutable(to: "/usr/local/bin/tmux")
        await host.startServer()
        await host.clearLog()

        let status = try await transport.status()

        #expect(status.paths.executable == "/usr/local/bin/tmux")
        #expect(await host.log == ["probe stored", "probe login"])
        #expect(await transport.resolvedPaths() == status.paths)
    }

    @Test func aRestartedServerIsAnotherInstance() async throws {
        let host = ScriptedTmuxHost()
        let transport = await host.transport(socketName: "default", storedPaths: stored)
        let first = try await transport.status().instance

        let restarted = TmuxServerInstance(pid: 9001, startTime: ScriptedTmuxHost.instance.startTime + 60)
        await host.startServer(instance: restarted)

        #expect(try await transport.status().instance == restarted)
        #expect(first != restarted)
    }

    @Test func aHostWithoutTmuxReadsNotInstalled() async throws {
        let host = ScriptedTmuxHost(executable: nil, sockets: [])
        let fresh = await host.transport(socketName: "default", storedPaths: nil)
        await #expect(throws: TransportError.tmuxNotInstalled) { try await fresh.status() }
        #expect(await host.log == ["probe login"])

        // Uninstalled since the paths were stored.
        await host.clearLog()
        let known = await host.transport(socketName: "default", storedPaths: stored)
        await #expect(throws: TransportError.tmuxNotInstalled) { try await known.status() }
        #expect(await host.log == ["probe stored", "probe login"])
        #expect(await known.resolvedPaths() == nil)
    }

    @Test func anOldTmuxReadsUpdateRequiredWithTheVersionFound() async throws {
        let host = ScriptedTmuxHost(version: "tmux 3.2a")
        for storedPaths in [stored, nil] {
            let transport = await host.transport(socketName: "default", storedPaths: storedPaths)
            await #expect(throws: TransportError.tmuxUpdateRequired(version: "3.2a")) {
                try await transport.status()
            }
        }
    }

    @Test func aProbeThatFailedSaysNothingOfTheHost() async throws {
        let host = ScriptedTmuxHost()
        let transport = await host.transport(socketName: "default", storedPaths: stored)

        await host.failNextProbe(.timedOut)
        await #expect(throws: TransportError.timedOut) { try await transport.status() }

        await host.answerNextProbe(stdout: "", exitStatus: 2)
        await #expect(throws: TransportError.malformedResponse("tmux: The probe exited with status 2.")) {
            try await transport.status()
        }

        await host.answerNextProbe(stdout: "Welcome to the Host\n")
        await #expect(throws: TransportError.malformedResponse("tmux: The probe's output is unreadable.")) {
            try await transport.status()
        }

        // None of that was the Host's answer, so the stored paths still stand.
        await host.clearLog()
        #expect(try await transport.status().paths == stored)
        #expect(await host.log == ["probe stored"])
    }

    @Test func closingClosesTheConnection() async throws {
        let host = ScriptedTmuxHost()
        let transport = await host.transport(socketName: "default", storedPaths: stored)
        #expect(await transport.isConnected)

        try await transport.close()

        #expect(await host.log == ["close"])
        #expect(await !transport.isConnected)
    }

    // MARK: What the user reads

    @Test func eachStateSaysWhatToDo() {
        let notRunning = TransportError.tmuxServerNotRunning(socketName: "default").presentation
        #expect(notRunning.summary == "No tmux server running")
        #expect(notRunning.detail == "No tmux server answers on the default socket")
        #expect(
            TransportError.tmuxServerNotRunning(socketName: "work").presentation.detail
                == "No tmux server answers on the socket \"work\"")

        let update = TransportError.tmuxUpdateRequired(version: "3.2a").presentation
        #expect(update.summary == "Update required")
        #expect(update.detail == "The Host has tmux 3.2a, and Heeler needs 3.3 or newer")

        #expect(TransportError.tmuxNotInstalled.presentation.summary == "tmux is not installed")
    }

    @Test func onlyAStoppedServerIsWorthAskingAgain() {
        #expect(TransportError.tmuxServerNotRunning(socketName: "default").isRetryable)
        #expect(!TransportError.tmuxNotInstalled.isRetryable)
        #expect(!TransportError.tmuxUpdateRequired(version: "3.2a").isRetryable)
    }

    @Test func eachStateFailsTheCheckItDisproves() {
        let checks = PreflightCheck.cases(for: .tmux)
        #expect(checks == [.connection, .remoteEnvironment, .herdrInstalled, .serverRunning])
        #expect(PreflightCheck.cases(for: .herdrCore) == PreflightCheck.allCases)
        #expect(PreflightCheck.herdrInstalled.title(for: .tmux) == "tmux installed")
        #expect(PreflightCheck.serverRunning.title(for: .tmux) == "tmux server running")

        func failed(_ error: TransportError) -> PreflightCheck? {
            let report = PreflightReport.failure(error, authMethod: .deviceKey)
            return checks.first { check in
                if case .failed = report[check] { true } else { false }
            }
        }
        #expect(failed(.tmuxNotInstalled) == .herdrInstalled)
        #expect(failed(.tmuxUpdateRequired(version: "3.2a")) == .herdrInstalled)
        #expect(failed(.tmuxServerNotRunning(socketName: "default")) == .serverRunning)
        let report = PreflightReport.failure(.tmuxUpdateRequired(version: "3.2a"), authMethod: .deviceKey)
        #expect(report.failureHint?.contains("3.2a") == true)
        #expect(report[.connection] == .passed)
    }

    @Test func aHostsSettingsCarryItsSocketNameAndStoredPaths() throws {
        var host = Host(
            address: "mac.example", username: "dev", serverKind: .tmux, sessionName: "work",
            tmuxPaths: ScriptedTmuxHost.paths("work"))
        let credentials = SSHCredentials.password("secret")
        let policy = HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true }

        var settings = SSHTransportSettings(host: host, credentials: credentials, hostKeyPolicy: policy)
        #expect(settings.serverKind == .tmux)
        #expect(settings.tmuxSocketName == "work")
        #expect(settings.tmuxPaths == ScriptedTmuxHost.paths("work"))

        // An edited socket name leaves paths that name another socket behind.
        host.sessionName = ""
        settings = SSHTransportSettings(host: host, credentials: credentials, hostKeyPolicy: policy)
        #expect(settings.tmuxSocketName == "default")
        #expect(settings.tmuxPaths == nil)
    }

    @Test func aConnectorThatServesNoTmuxHostsSaysSo() async throws {
        struct HerdrOnly: TransportConnector {
            func connect(settings: SSHTransportSettings) async throws -> any Transport {
                throw TransportError.cancelled
            }
        }
        let settings = SSHTransportSettings(
            host: Host(address: "mac.example", username: "dev", serverKind: .tmux),
            credentials: .password("secret"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true })

        await #expect(throws: TransportError.hostFeatureUnavailable(feature: "tmux Hosts")) {
            _ = try await HerdrOnly().connectTmux(settings: settings)
        }
        // The Herdr TUI transport never dials a tmux Host.
        await #expect(throws: TransportError.hostFeatureUnavailable(feature: "Herdr TUI on a tmux Host")) {
            _ = try await SSHTransportConnector().connect(settings: settings)
        }
    }
}
