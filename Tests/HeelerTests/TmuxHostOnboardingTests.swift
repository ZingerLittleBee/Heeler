import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("tmux Host onboarding")
struct TmuxHostOnboardingTests {
    /// Records the paths the store asks its catalog to keep.
    @MainActor
    private final class NotedPaths {
        var notes: [(Host.ID, TmuxPaths)] = []
    }

    private func makeStore(
        _ host: Host, tmux: ScriptedTmuxHost,
        outcome: FakeTransportConnector.Outcome = .connects(pingResult: .failure(.cancelled)),
        noted: NotedPaths = NotedPaths()
    ) -> (HostOnboardingStore, FakeTransportConnector) {
        let connector = FakeTransportConnector(outcome: outcome, tmux: tmux)
        let store = HostOnboardingStore(
            host: host,
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            noteTmuxPaths: { noted.notes.append(($0, $1)) })
        return (store, connector)
    }

    private func failedCheck(_ store: HostOnboardingStore) -> (PreflightCheck, String)? {
        guard let report = store.report else { return nil }
        for check in PreflightCheck.cases(for: store.host.serverKind) {
            if case .failed(let hint) = report[check] { return (check, hint) }
        }
        return nil
    }

    // MARK: A tmux Host's checks

    private func confirmedHost(paths: TmuxPaths? = ScriptedTmuxHost.paths(), socket: String = "default") -> Host {
        Host(
            address: "mac.example", username: "dev", serverKind: .tmux, sessionName: socket, tmuxPaths: paths)
    }

    /// Nothing but the tmux transport dials, with the paths the Host stores, and
    /// what a Herdr Host would read beside its checks reads as a tmux Host's.
    @Test func aTmuxHostsChecksDialOnlyTmux() async throws {
        let tmux = ScriptedTmuxHost()
        let (store, connector) = makeStore(confirmedHost(), tmux: tmux)

        await store.runChecks()

        #expect(store.report == .allPassed)
        #expect(store.phase == .finished)
        #expect(store.serverKindSummary == "tmux 3.7b")
        #expect(store.pluginStatus == .unsupportedServerKind)
        #expect(store.hostHelper?.status == .notInstalled)
        #expect(await connector.transports.isEmpty)
        #expect(await connector.capturedSettings.last?.serverKind == .tmux)
        #expect(await connector.capturedSettings.last?.tmuxPaths == ScriptedTmuxHost.paths())
    }

    @Test func aSocketWithNoServerIsNamedAndNoneIsStarted() async throws {
        let tmux = ScriptedTmuxHost(sockets: [])
        let (store, _) = makeStore(
            confirmedHost(paths: ScriptedTmuxHost.paths("later"), socket: "later"), tmux: tmux)

        await store.runChecks()

        let (check, hint) = try #require(failedCheck(store))
        #expect(check == .serverRunning)
        #expect(hint.contains("No tmux server running"))
        #expect(hint.contains("\"later\""))
        #expect(store.report?[.herdrInstalled] == .passed)
        // Checking started no server.
        for script in await tmux.scripts {
            #expect(!script.contains("new-session"))
        }
    }

    @Test func aHostWithoutTmuxReadsNotInstalled() async throws {
        let tmux = ScriptedTmuxHost(executable: nil, sockets: [])
        let (store, _) = makeStore(confirmedHost(paths: nil), tmux: tmux)

        await store.runChecks()

        #expect(store.host.tmuxPaths == nil)
        let (check, hint) = try #require(failedCheck(store))
        #expect(check == .herdrInstalled)
        #expect(hint.contains("tmux is not installed"))
        #expect(store.report?[.serverRunning] == .blocked)
        #expect(store.serverKindSummary == "tmux")
    }

    @Test func anOldTmuxReadsUpdateRequiredWithTheVersionFound() async throws {
        let tmux = ScriptedTmuxHost(version: "tmux 3.2a")
        let (store, _) = makeStore(confirmedHost(paths: nil), tmux: tmux)

        await store.runChecks()

        let (check, hint) = try #require(failedCheck(store))
        #expect(check == .herdrInstalled)
        #expect(hint.contains("Update required"))
        #expect(hint.contains("3.2a"))
        #expect(hint.contains("3.3"))
    }

    /// Nothing was resolved when the Server was turned on, so the first
    /// connection asks the login shell, and what it finds is kept.
    @Test func aHostWithNoStoredPathsAsksTheLoginShellAndKeepsWhatItFinds() async throws {
        let tmux = ScriptedTmuxHost()
        let (store, _) = makeStore(confirmedHost(paths: nil), tmux: tmux)

        await store.runChecks()

        #expect(store.report == .allPassed)
        #expect(await tmux.log == ["probe login", "close"])
        #expect(store.host.storedTmuxPaths == ScriptedTmuxHost.paths())
    }

    @Test func aConfirmedHostsChecksAskOnlyItsStoredPaths() async throws {
        let tmux = ScriptedTmuxHost()
        let noted = NotedPaths()
        let (store, connector) = makeStore(confirmedHost(), tmux: tmux, noted: noted)

        await store.runChecks()

        #expect(store.report == .allPassed)
        #expect(await tmux.log == ["probe stored", "close"])
        #expect(noted.notes.isEmpty)
        #expect(await connector.transports.isEmpty)
        #expect(PreflightCheck.cases(for: .tmux).allSatisfy { store.report?[$0] == .passed })
    }

    /// The acceptance case, at the checks: the stored executable moved.
    @Test func pathsThatStoppedAnsweringAreResolvedAgainAndKept() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.moveExecutable(to: "/usr/local/bin/tmux")
        let noted = NotedPaths()
        let host = confirmedHost()
        let (store, _) = makeStore(host, tmux: tmux, noted: noted)

        await store.runChecks()

        let moved = try #require(
            TmuxPaths(executable: "/usr/local/bin/tmux", socket: ScriptedTmuxHost.socketPath()))
        #expect(store.report == .allPassed)
        #expect(await tmux.log == ["probe stored", "probe login", "close"])
        #expect(store.host.tmuxPaths == moved)
        #expect(noted.notes.count == 1)
        #expect(noted.notes.first?.0 == host.id)
        #expect(noted.notes.first?.1 == moved)
    }

    @Test func aStoppedServerReadsNoTmuxServerRunning() async throws {
        let tmux = ScriptedTmuxHost(sockets: [])
        let (store, _) = makeStore(confirmedHost(), tmux: tmux)

        await store.runChecks()

        let (check, hint) = try #require(failedCheck(store))
        #expect(check == .serverRunning)
        #expect(hint.contains("No tmux server running"))
        #expect(await tmux.log.last == "close")
    }

    @Test func aHostOutOfReachFailsItsConnection() async throws {
        let tmux = ScriptedTmuxHost()
        let (store, _) = makeStore(
            confirmedHost(), tmux: tmux, outcome: .connectFails(.sshUnreachable(detail: "refused")))

        await store.runChecks()

        let (check, _) = try #require(failedCheck(store))
        #expect(check == .connection)
        #expect(await tmux.log.isEmpty)
    }

    @Test func runningTheChecksAgainForgetsTheLastAnswer() async throws {
        let tmux = ScriptedTmuxHost()
        let (store, _) = makeStore(confirmedHost(), tmux: tmux)
        await store.runChecks()
        #expect(store.serverKindSummary == "tmux 3.7b")

        await tmux.uninstall()
        await store.runChecks()

        #expect(store.serverKindSummary == "tmux")
        #expect(failedCheck(store)?.0 == .herdrInstalled)
    }

    @Test func theHostHelperInstallsStoredPathsEvenWithNoServerRunningAndRemovalKeepsThem() async throws {
        let tmux = ScriptedTmuxHost(sockets: [], kernel: "Linux")
        let host = Host(address: "linux.example", username: "dev", serverKind: .tmux, sessionName: "work")
        let (store, _) = makeStore(host, tmux: tmux)

        await store.runChecks()

        let helper = try #require(store.hostHelper)
        #expect(failedCheck(store)?.0 == .serverRunning)
        #expect(store.host.storedTmuxPaths == ScriptedTmuxHost.paths("work"))
        #expect(helper.status == .notInstalled)

        let pathsFile = "\(await tmux.dataHome)/heeler/host-helper/tmux/work/paths.json"
        #expect(helper.plan?.files.contains(pathsFile) == true)

        await helper.install()
        #expect(helper.failure == nil)
        #expect(helper.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
        #expect(await tmux.helper.files[pathsFile]?.contents == TmuxClaudeCodeHooks.storedPaths(ScriptedTmuxHost.paths("work")))

        await helper.remove()
        #expect(helper.failure == nil)
        #expect(helper.status == .notInstalled)
        #expect(await tmux.helper.filePaths() == [pathsFile])
    }

    @Test func anAlreadyInstalledHelperGetsTheTmuxHostsStoredPathsWithoutAnotherInstall() async throws {
        let tmux = ScriptedTmuxHost(sockets: ["work"], kernel: "Linux")
        let installer = HostHelperInstaller(host: tmux.helper, healthGap: {})
        let before = try await installer.check()
        _ = try await installer.install(over: before, bundle: try HostHelperBundle.load())
        let workPathsFile = "\(await tmux.dataHome)/heeler/host-helper/tmux/work/paths.json"
        #expect(await tmux.helper.files[workPathsFile] == nil)

        let host = Host(address: "linux.example", username: "dev", serverKind: .tmux, sessionName: "work")
        let (store, _) = makeStore(host, tmux: tmux)
        await store.runChecks()

        let helper = try #require(store.hostHelper)
        #expect(helper.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
        #expect(helper.plan == nil)
        #expect(
            await tmux.helper.files[workPathsFile]?.contents
                == TmuxClaudeCodeHooks.storedPaths(ScriptedTmuxHost.paths("work")))
    }
}
