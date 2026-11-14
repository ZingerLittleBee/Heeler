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

    /// An unconfirmed Host in a catalog of its own, with its store.
    private func unconfirmedStore(
        _ tmux: ScriptedTmuxHost, session: String = ""
    ) -> (HostOnboardingStore, FakeTransportConnector, HostStore) {
        let host = Host(address: "mac.example", username: "dev", serverKind: .unconfirmed, sessionName: session)
        let catalog = HostStore(volatileHosts: [host])
        let (store, connector) = makeStore(host, tmux: tmux)
        return (store, connector, catalog)
    }

    private func failedCheck(_ store: HostOnboardingStore) -> (PreflightCheck, String)? {
        guard let report = store.report else { return nil }
        for check in PreflightCheck.cases(for: store.host.serverKind) {
            if case .failed(let hint) = report[check] { return (check, hint) }
        }
        return nil
    }

    // MARK: Detection

    @Test func detectionOffersTmuxWithTheSocketsItsServersAnswerOn() async throws {
        let tmux = ScriptedTmuxHost(sockets: ["work", "default"])
        let (store, connector, _) = unconfirmedStore(tmux)

        await store.runChecks()

        #expect(store.detection?.tmux == .running(version: "3.7b", sockets: ["default", "work"]))
        #expect(store.offeredKinds == [.tmux])
        #expect(store.tmuxSocketChoices == ["default", "work"])
        #expect(store.tmuxSocket == "default")
        #expect(store.confirmationNote == nil)
        #expect(await tmux.log == ["detection", "close"])
        #expect(await connector.transports.isEmpty)
        #expect(store.host.serverKind == .unconfirmed)
    }

    @Test func theTypedSocketIsPreselectedWhenItsServerAnswers() async throws {
        let tmux = ScriptedTmuxHost(sockets: ["default", "work"])
        let (store, _, _) = unconfirmedStore(tmux, session: "work")

        await store.runChecks()

        #expect(store.tmuxSocket == "work")
    }

    @Test func onlyAnOfferedSocketCanBeChosen() async throws {
        let tmux = ScriptedTmuxHost(sockets: ["default", "work"])
        let (store, _, _) = unconfirmedStore(tmux)
        await store.runChecks()

        store.selectTmuxSocket("elsewhere")
        #expect(store.tmuxSocket == "default")

        store.selectTmuxSocket("work")
        #expect(store.tmuxSocket == "work")
    }

    // MARK: Confirmation

    @Test func confirmingTmuxStoresTheSocketAndThePathsDetectionResolved() async throws {
        let tmux = ScriptedTmuxHost()
        let (store, connector, catalog) = unconfirmedStore(tmux)
        await store.runChecks()

        await store.confirmServerKind(.tmux, in: catalog)

        #expect(store.host.serverKind == .tmux)
        #expect(store.host.sessionName == "default")
        #expect(store.host.storedTmuxPaths == ScriptedTmuxHost.paths())
        #expect(catalog.hosts == [store.host])
        // Its checks follow at once, with the paths detection just resolved:
        // no startup file runs a second time.
        #expect(store.report == .allPassed)
        #expect(store.phase == .finished)
        #expect(await tmux.log == ["detection", "close", "probe stored", "close"])
        #expect(store.serverKindSummary == "tmux 3.7b")
        #expect(store.pluginStatus == .unsupportedServerKind)
        #expect(store.hostHelper?.status == .notInstalled)
        #expect(store.offeredKinds.isEmpty)
        // Nothing but the tmux transport ever dialed.
        #expect(await connector.transports.isEmpty)
        #expect(await connector.capturedSettings.last?.serverKind == .tmux)
        #expect(await connector.capturedSettings.last?.tmuxPaths == ScriptedTmuxHost.paths())
    }

    @Test func theChosenSocketIsTheOneConfirmed() async throws {
        let tmux = ScriptedTmuxHost(sockets: ["default", "work"])
        let (store, _, catalog) = unconfirmedStore(tmux)
        await store.runChecks()
        store.selectTmuxSocket("work")

        await store.confirmServerKind(.tmux, in: catalog)

        #expect(store.host.sessionName == "work")
        #expect(store.host.storedTmuxPaths == ScriptedTmuxHost.paths("work"))
        #expect(store.report == .allPassed)
        #expect(catalog.hosts.first?.sessionName == "work")
    }

    @Test func aHostWithNoServerRunningCanStillBeConfirmed() async throws {
        let tmux = ScriptedTmuxHost(sockets: [])
        let (store, _, catalog) = unconfirmedStore(tmux, session: "later")
        await store.runChecks()
        #expect(store.detection?.tmux == .notRunning(version: "3.7b"))
        #expect(store.offeredKinds == [.herdrTUI, .herdrCore, .tmux])
        #expect(store.tmuxSocketChoices.isEmpty)
        #expect(store.tmuxSocket == "later")

        await store.confirmServerKind(.tmux, in: catalog)

        #expect(store.host.serverKind == .tmux)
        #expect(store.host.sessionName == "later")
        #expect(store.host.storedTmuxPaths == ScriptedTmuxHost.paths("later"))
        let (check, hint) = try #require(failedCheck(store))
        #expect(check == .serverRunning)
        #expect(hint.contains("No tmux server running"))
        #expect(hint.contains("\"later\""))
        #expect(store.report?[.herdrInstalled] == .passed)
        // Confirming and checking started no server.
        for script in await tmux.scripts {
            #expect(!script.contains("new-session"))
        }
    }

    @Test func aSocketPathIsRefusedAndTheHostStaysUnconfirmed() async throws {
        let tmux = ScriptedTmuxHost(sockets: [])
        let (store, _, catalog) = unconfirmedStore(tmux, session: "/tmp/tmux-501/default")
        await store.runChecks()

        await store.confirmServerKind(.tmux, in: catalog)

        #expect(store.confirmationRefusal == ServerKind.tmux.sessionNameRefusal("/tmp/tmux-501/default"))
        #expect(store.confirmationRefusal?.contains("A socket path is not supported") == true)
        #expect(store.host.serverKind == .unconfirmed)
        #expect(catalog.hosts.first?.serverKind == .unconfirmed)
        #expect(await tmux.log == ["detection", "close"])
    }

    @Test func aHostWithoutTmuxReadsNotInstalledOnceConfirmed() async throws {
        let tmux = ScriptedTmuxHost(executable: nil, sockets: [])
        let (store, _, catalog) = unconfirmedStore(tmux)
        await store.runChecks()
        #expect(store.detection?.tmux == .notInstalled)
        #expect(store.offeredKinds == [.herdrTUI, .herdrCore, .tmux])
        #expect(store.confirmationNote?.contains("None of them was found") == true)

        await store.confirmServerKind(.tmux, in: catalog)

        #expect(store.host.serverKind == .tmux)
        #expect(store.host.tmuxPaths == nil)
        let (check, hint) = try #require(failedCheck(store))
        #expect(check == .herdrInstalled)
        #expect(hint.contains("tmux is not installed"))
        #expect(store.report?[.serverRunning] == .blocked)
        #expect(store.serverKindSummary == "tmux")
    }

    @Test func anOldTmuxReadsUpdateRequiredWithTheVersionFound() async throws {
        let tmux = ScriptedTmuxHost(version: "tmux 3.2a")
        let (store, _, catalog) = unconfirmedStore(tmux)
        await store.runChecks()
        #expect(store.detection?.tmux == .updateRequired(version: "3.2a"))

        await store.confirmServerKind(.tmux, in: catalog)

        let (check, hint) = try #require(failedCheck(store))
        #expect(check == .herdrInstalled)
        #expect(hint.contains("Update required"))
        #expect(hint.contains("3.2a"))
        #expect(hint.contains("3.3"))
    }

    @Test func aDetectionThatFailsStillLetsTmuxBeConfirmed() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.failNextProbe(.malformedResponse("Server Kind detection's output is unreadable."))
        let (store, _, catalog) = unconfirmedStore(tmux)
        await store.runChecks()
        #expect(store.detection == nil)
        #expect(store.offeredKinds == [.herdrTUI, .herdrCore, .tmux])
        #expect(store.tmuxSocket == "default")

        await store.confirmServerKind(.tmux, in: catalog)

        // Nothing was resolved, so the first connection asks the login shell,
        // and what it finds is kept.
        #expect(store.report == .allPassed)
        #expect(await tmux.log == ["detection", "close", "probe login", "close"])
        #expect(store.host.storedTmuxPaths == ScriptedTmuxHost.paths())
    }

    @Test func anUnreadableTmuxCatalogRefusesInWords() async throws {
        let suite = "tmux-onboarding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{not json".utf8), forKey: "tmuxHosts")
        let catalog = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let host = Host(address: "mac.example", username: "dev", serverKind: .unconfirmed)
        try catalog.add(host)
        let tmux = ScriptedTmuxHost()
        let (store, _) = makeStore(host, tmux: tmux)
        await store.runChecks()

        await store.confirmServerKind(.tmux, in: catalog)

        #expect(store.confirmationRefusal == "The saved tmux Hosts could not be read, so no tmux Host can be added.")
        #expect(store.host.serverKind == .unconfirmed)
    }

    // MARK: A confirmed tmux Host's checks

    private func confirmedHost(paths: TmuxPaths? = ScriptedTmuxHost.paths(), socket: String = "default") -> Host {
        Host(
            address: "mac.example", username: "dev", serverKind: .tmux, sessionName: socket, tmuxPaths: paths)
    }

    @Test func aConfirmedHostsChecksAskOnlyItsStoredPaths() async throws {
        let tmux = ScriptedTmuxHost()
        let noted = NotedPaths()
        let (store, connector) = makeStore(confirmedHost(), tmux: tmux, noted: noted)

        await store.runChecks()

        #expect(store.report == .allPassed)
        #expect(store.detection == nil)
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

    // MARK: What the confirmation says

    @Test func theNoteCountsTheKindsFound() async throws {
        let all = ScriptedCoreHost(
            herdrRead: .answers(#"{"sessions":[{"name":"default","default":true,"running":true}]}"#),
            tmuxProbe: ScriptedCoreHost.tmuxLines(executable: "/usr/bin/tmux", sockets: ["default"]),
            channel: .refused)
        let host = Host(address: "box.example", username: "dev", serverKind: .unconfirmed)
        let connector = FakeTransportConnector(outcome: .connects(pingResult: .failure(.cancelled)), core: all)
        let store = HostOnboardingStore(
            host: host, connector: connector, knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()))

        await store.runChecks()

        #expect(store.detection?.foundKinds == [.herdrTUI, .herdrCore, .tmux])
        #expect(store.confirmationNote?.contains("more than one") == true)
    }
}
