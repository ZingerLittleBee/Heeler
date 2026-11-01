import Foundation
import Testing

@testable import Heeler

/// What Host detail and the install sheet read and do, through the real framed
/// transport over a scripted Host.
@Suite("Host Helper store")
@MainActor
struct HostHelperStoreTests {
    private let helper = ScriptedHelperHost()
    private let bundle = HostHelperFixture.bundle()

    private func makeStore() -> HostHelperStore {
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let bundle = bundle
        return HostHelperStore(connect: { core.transport() }, bundle: { bundle })
    }

    private func refreshed() async -> HostHelperStore {
        let store = makeStore()
        await store.refresh()
        return store
    }

    @Test func readsAHostWithNoCoreRunning() async {
        let store = await refreshed()
        #expect(store.status == .notInstalled)
        #expect(store.rowValue == "Not Installed")
        #expect(store.installAction == .install)
    }

    @Test func theFileListIsThePlanTheInstallCarriesOut() async throws {
        let store = await refreshed()
        let listed = try #require(store.plan?.files)
        #expect(listed.contains(ScriptedHelperHost.unit))
        let before = await helper.filePaths()
        await store.install()
        #expect(store.failure == nil)
        #expect(await helper.filePaths().subtracting(before) == Set(listed))
    }

    @Test func theSheetListsTheExtensionsAndRemovalLeavesNoneBehind() async throws {
        await helper.seedFolder("/home/me/.omp/profiles/work")
        let store = await refreshed()
        let listed = try #require(store.plan?.files)
        let extensions = [
            "/home/me/.pi/agent/extensions/heeler-session.js",
            "/home/me/.omp/agent/extensions/heeler-session.js",
            "/home/me/.omp/profiles/work/agent/extensions/heeler-session.js",
        ]
        for file in extensions { #expect(listed.contains(file), "\(file)") }
        await store.install()
        #expect(store.failure == nil)
        for file in extensions { #expect(await helper.files[file] != nil, "\(file)") }
        await store.remove()
        #expect(store.failure == nil)
        #expect(await helper.filePaths().isEmpty)
    }

    @Test func installsAndReadsTheHostBack() async {
        let store = await refreshed()
        await store.install()
        #expect(store.status == .installed(version: HostHelperCompatibility.bundled, updateAvailable: false))
        #expect(store.installAction == nil)
        #expect(store.plan == nil)
        #expect(store.offersRemoval)
    }

    /// Another device may have installed a newer Helper since the sheet read.
    @Test func anInstallGoesByWhatTheHostSaysNow() async throws {
        let store = await refreshed()
        let otherDevice = HostHelperInstaller(host: helper)
        _ = try await otherDevice.install(
            over: try await otherDevice.read(), bundle: HostHelperFixture.bundle(version: "9.9.9"))
        await helper.configure { $0.clearLog() }

        await store.install()

        #expect(store.failure == HostHelperError.newerInstalled(version: PluginVersion(9, 9, 9)).message)
        #expect(store.status == .newer(version: PluginVersion(9, 9, 9)))
        #expect(await helper.writes.isEmpty)
    }

    @Test func aFailedServiceShowsOnTheRowAndOffersRepair() async {
        let store = await refreshed()
        await store.install()
        await helper.configure {
            $0.activeState = "failed"
            $0.result = "start-limit-hit"
            $0.restarts = 5
        }
        await store.refresh()
        #expect(store.rowValue == "Service Failed")
        #expect(store.needsAttention)
        #expect(store.installAction == .repair)
        #expect(store.detail?.contains("start-limit-hit") == true)
    }

    @Test func removesAndReadsTheHostBack() async {
        let store = await refreshed()
        await store.install()
        await store.remove()
        #expect(store.failure == nil)
        #expect(store.status == .notInstalled)
        #expect(await helper.filePaths().isEmpty)
    }

    @Test func offersLingerAndTurnsItOn() async {
        await helper.configure { $0.lingerOn = false }
        let store = await refreshed()
        #expect(store.offersLinger)
        await store.turnOnLinger()
        #expect(store.failure == nil)
        #expect(!store.offersLinger)
    }

    @Test func aHostThatAsksForAnAdministratorIsShownToTheUser() async throws {
        let reason = "Could not enable linger: Interactive authentication required."
        await helper.configure {
            $0.lingerOn = false
            $0.lingerRefusal = reason
        }
        let store = await refreshed()
        await store.turnOnLinger()
        let failure = try #require(store.failure)
        #expect(failure.contains(reason))
        #expect(failure.contains("sudo loginctl enable-linger me"))
        #expect(store.offersLinger)
    }

    @Test func aNewCheckClearsTheLastActionsFailure() async throws {
        await helper.configure {
            $0.lingerOn = false
            $0.lingerRefusal = "Interactive authentication required."
        }
        let store = await refreshed()
        await store.turnOnLinger()
        #expect(store.failure != nil)

        // An administrator turned it on at the Host, and the user checks again.
        await helper.configure { $0.lingerOn = true }
        await store.refresh()
        #expect(store.failure == nil)
        #expect(!store.offersLinger)
    }

    @Test func aCheckOverTheCallersConnectionClearsItToo() async throws {
        await helper.configure {
            $0.lingerOn = false
            $0.lingerRefusal = "Interactive authentication required."
        }
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let bundle = bundle
        let store = HostHelperStore(connect: { core.transport() }, bundle: { bundle })
        await store.refresh()
        await store.turnOnLinger()
        #expect(store.failure != nil)

        await store.refresh(over: core.transport())
        #expect(store.failure == nil)
    }

    @Test func aRefusedConnectionChangesNothingAndSaysSo() async throws {
        let store = HostHelperStore(connect: { throw TransportError.authenticationFailed }, bundle: { [bundle] in bundle })
        await store.install()
        let failure = try #require(store.failure)
        #expect(failure.hasPrefix("Heeler could not connect to the Host, so nothing changed."))
        await store.refresh()
        if case .unavailable = store.reading {} else { Issue.record("Expected the read to be unavailable") }
        #expect(store.rowValue == "Unavailable")
    }

    @Test func aHostThatCannotBeAskedListsNoFiles() async throws {
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let bundle = bundle
        let store = HostHelperStore(connect: { throw TransportError.timedOut }, bundle: { bundle })
        await store.refresh(over: core.transport())
        #expect(store.plan != nil)

        await store.refresh()
        #expect(store.rowValue == "Unavailable")
        #expect(store.plan == nil)
    }

    @Test func aBuildWithoutTheHelperSaysSoAndLeavesTheHostAlone() async {
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let store = HostHelperStore(
            connect: { core.transport() }, bundle: { throw HostHelperBundle.LoadError.missing })
        await store.refresh()
        #expect(store.plan == nil)
        await store.install()
        #expect(store.failure == HostHelperError.bundleUnavailable.message)
        #expect(await helper.writes.isEmpty)
    }

    /// The Node.js listing failed on the read behind the sheet, and works now.
    @Test func anInstallWithNoListShownListsFirstAndWritesNothing() async throws {
        await helper.configure { $0.extensionFoldersFailure = "node: bad option" }
        let store = await refreshed()
        #expect(store.plan == nil)
        #expect(store.installAction == .install)
        await helper.configure { $0.extensionFoldersFailure = nil }

        await store.install()

        #expect(await helper.writes.isEmpty)
        #expect(store.failure == nil)
        let listed = try #require(store.plan?.files)

        await store.install()

        #expect(store.failure == nil)
        #expect(await helper.filePaths().isSuperset(of: Set(listed)))
    }

    @Test func anInstallWhoseListStaysUnreadableSaysWhyAndWritesNothing() async throws {
        await helper.configure { $0.extensionFoldersFailure = "node: bad option" }
        let store = await refreshed()

        await store.install()

        #expect(await helper.writes.isEmpty)
        #expect(store.plan == nil)
        #expect(store.failure == HostHelperError.extensionFoldersUnreadable.message)
    }

    @Test func eachActionSaysItMayHaveChangedTheHelperOnceItHasReadTheHostBack() async throws {
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let bundle = bundle
        let store = HostHelperStore(connect: { core.transport() }, bundle: { bundle })
        var heard: [HostHelperStatus?] = []
        store.onChanged = { heard.append(store.status) }
        await store.refresh()
        #expect(heard.isEmpty)

        await store.install()
        #expect(heard == [.installed(version: HostHelperCompatibility.bundled, updateAvailable: false)])

        await store.remove()
        #expect(heard.last == .notInstalled)
        #expect(heard.count == 2)
    }

    @Test func anActionThatNeverReachedTheHostSaysNothingChanged() async throws {
        let bundle = bundle
        let store = HostHelperStore(connect: { throw TransportError.timedOut }, bundle: { bundle })
        var heard = 0
        store.onChanged = { heard += 1 }
        await store.remove()
        #expect(store.failure != nil)
        #expect(heard == 0)
    }

    @Test func aNativeWindowsHostNamesWhatComesWithTheHelper() async throws {
        await helper.configure { $0.platform = .nativeWindows }
        let store = await refreshed()
        #expect(store.status == .unsupportedPlatform(.nativeWindows))
        let detail = try #require(store.detail)
        #expect(detail.contains("Agent Notifications (in-app banners included), Live Activity and Usage"))
        #expect(store.installAction == nil)
    }
}

/// Which directory a Host's notification and Usage files come from.
@Suite("Host notification files by Server Kind")
@MainActor
struct HostNotificationFilesRoutingTests {
    private let directory = ScriptedHelperHost.helperDirectory

    private func coreConsole(_ helper: ScriptedHelperHost) -> (ConsoleStore, Host, ScriptedCoreHost) {
        let core = ScriptedCoreHost(helper: helper, channel: .refused)
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: { ScriptedTransport(snapshot: .fixture(agents: [])) }, keepalive: nil)
            },
            connectCore: { _ in core.transport() })
        console.setHosts([host])
        return (console, host, core)
    }

    @Test func aCoreHostsRegistrationAndConfigAreRootedAtTheHelperDirectory() async throws {
        let helper = ScriptedHelperHost()
        await helper.seedFolder(directory)
        await helper.seedFile("\(directory)/notifications.json", Data("registered".utf8))
        await helper.seedFile("\(directory)/notify.json", Data("config".utf8))
        let (console, host, _) = coreConsole(helper)
        defer { console.setHosts([]) }

        let registration = try await console.withNotificationFiles(for: host.id) {
            try await $0.readNotificationRegistration()
        }
        let config = try await console.withNotificationFiles(for: host.id) {
            try await $0.readNotificationConfig()
        }
        try await console.withNotificationFiles(for: host.id) {
            try await $0.replaceNotificationRegistration(Data("changed".utf8))
        }
        try await console.withNotificationFiles(for: host.id) {
            try await $0.replaceNotificationConfig(Data("changed config".utf8))
        }

        #expect(registration == Data("registered".utf8))
        #expect(config == Data("config".utf8))
        #expect(await helper.files["\(directory)/notifications.json"]?.contents == Data("changed".utf8))
        #expect(await helper.files["\(directory)/notify.json"]?.contents == Data("changed config".utf8))
        #expect(await helper.writes.allSatisfy { $0.privateDirectory == directory })
        #expect(await helper.reads.allSatisfy { $0.hasPrefix(directory) })
    }

    @Test func aCoreHostsUsageAccountFileIsRootedAtTheHelperDirectory() async throws {
        let helper = ScriptedHelperHost()
        await helper.seedFolder(directory)
        let (console, host, _) = coreConsole(helper)
        defer { console.setHosts([]) }

        try await console.withNotificationFiles(for: host.id) {
            try await $0.replaceUsageAccountFile(Data("accounts".utf8))
        }
        let read = try await console.withNotificationFiles(for: host.id) {
            try await $0.readUsageAccountFile()
        }

        #expect(read == Data("accounts".utf8))
        #expect(await helper.reads == ["\(directory)/\(UsageAccountFile.fileName)"])
    }

    @Test func aCoreHostsUsageQueryIsTheHelpers() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        await helper.seedUsage(Data(#"{"version":1,"runtime":"missing"}"#.utf8), session: "default")
        let (console, host, _) = coreConsole(helper)
        defer { console.setHosts([]) }
        let report = try await console.withNotificationFiles(for: host.id) {
            try await $0.readAgentUsage(timeZone: "UTC", claudeLimits: false, pluginRoot: "/plugin")
        }
        #expect(report.runtime == "missing")
    }

    @Test func aCoreHostsFilesCloseTheConnectionTheyDialed() async throws {
        let helper = ScriptedHelperHost()
        await helper.seedFolder(directory)
        let (console, host, core) = coreConsole(helper)
        defer { console.setHosts([]) }
        _ = try await console.withNotificationFiles(for: host.id) { try await $0.readNotificationConfig() }
        #expect(await core.log == ["close"])
    }

    @Test func aCoreHostsFilesAreNeverThePluginsTransport() async throws {
        let (console, host, _) = coreConsole(ScriptedHelperHost())
        defer { console.setHosts([]) }
        await #expect(throws: HeelerPluginUnavailableError.self) {
            try await console.withNotificationTransport(for: host.id) { _ in () }
        }
    }

    @Test func aHerdrTUIHostsFilesStayThePlugins() async throws {
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        await transport.setNotificationRegistration(Data("plugin's".utf8))
        let host = Host.fixture()
        let helper = ScriptedHelperHost()
        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
            },
            connectCore: { _ in
                Issue.record("A Herdr TUI Host never dials a core connection")
                return ScriptedCoreHost(helper: helper, channel: .refused).transport()
            })
        defer { console.setHosts([]) }
        console.setHosts([host])
        await console.resume()
        let deadline = ContinuousClock.now + .seconds(5)
        while console.hostStatuses[host.id] != .connected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(console.hostStatuses[host.id] == .connected)

        let read = try await console.withNotificationFiles(for: host.id) {
            try await $0.readNotificationRegistration()
        }
        try await console.withNotificationFiles(for: host.id) {
            try await $0.replaceUsageAccountFile(Data("accounts".utf8))
        }

        #expect(read == Data("plugin's".utf8))
        #expect(await transport.notificationRegistrationReads == 1)
        #expect(await transport.replacedUsageAccountFiles == [Data("accounts".utf8)])
        #expect(await helper.journal.isEmpty)
    }

    /// A provider that serves only Herdr TUI Hosts keeps offering the plugin's.
    @Test func aProviderOfHerdrTUIHostsOnlyOffersThePlugins() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        await transport.setNotificationRegistration(Data("plugin's".utf8))
        let provider = ScriptedTransportProvider(transports: [host.id: transport])
        let read = try await provider.withNotificationFiles(for: host.id) {
            try await $0.readNotificationRegistration()
        }
        #expect(read == Data("plugin's".utf8))
    }
}

/// Host detail's reading of a core Host's Helper.
@Suite("Host Helper on Host detail")
@MainActor
struct HostHelperOnboardingTests {
    private static let unreachableHint =
        "Could not reach the Host over SSH. Check the address and port. (no route)"
    private static let cancelledHint = "The check was cancelled before it finished."

    private let secrets = InMemorySecretStore()
    private var credentials: HostCredentialsProvider {
        HostCredentialsProvider(
            deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
            rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
            secrets: secrets)
    }

    private func coreStore(
        _ connector: FakeTransportConnector, authMethod: Host.AuthMethod = .deviceKey
    ) -> HostOnboardingStore {
        HostOnboardingStore(
            host: Host(
                address: "box.example", username: "dev", authMethod: authMethod,
                serverKind: .herdrCore, sessionName: "work"),
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: credentials)
    }

    private func coreStore(_ core: ScriptedCoreHost) throws -> HostOnboardingStore {
        coreStore(reaching(core))
    }

    private func reaching(_ core: ScriptedCoreHost) -> FakeTransportConnector {
        FakeTransportConnector(
            outcome: .connects(pingResult: .success(ServerInfo(version: "0", protocolVersion: 1))), core: core)
    }

    private func waitUntilRunning(_ store: HostOnboardingStore) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while store.phase != .running, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(store.phase == .running)
    }

    @Test func thePreflightReadsTheHelperAndLeavesTheCoreLogAlone() async throws {
        let helper = ScriptedHelperHost()
        let core = ScriptedCoreHost(helper: helper, channel: .answersHello(ScriptedCoreHost.helloReply()))
        let store = try coreStore(core)
        await store.runChecks()
        #expect(store.hostHelper?.status == .notInstalled)
        #expect(await core.log == ["locator", "open \(ScriptedCoreHost.socketPath)", "close"])
    }

    @Test func theHelperReadsWhileNoCoreRuns() async throws {
        let core = ScriptedCoreHost(channel: .refused)
        let store = try coreStore(core)
        await store.runChecks()
        #expect(store.report?.isFullyPassed != true)
        #expect(store.hostHelper?.status == .notInstalled)
    }

    @Test func aHostOutOfReachOnTheFirstCheckReadsAsUnavailable() async throws {
        let store = coreStore(
            FakeTransportConnector(outcome: .connectFails(.sshUnreachable(detail: "no route"))))
        await store.runChecks()
        let helper = try #require(store.hostHelper)
        #expect(helper.reading == .unavailable(message: Self.unreachableHint))
        #expect(helper.rowValue == "Unavailable")
        #expect(helper.detail == Self.unreachableHint)
    }

    @Test func aHostOutOfReachOnALaterCheckDropsAnInstalledReading() async throws {
        let connector = reaching(ScriptedCoreHost(helper: ScriptedHelperHost(), channel: .refused))
        let store = coreStore(connector)
        await store.runChecks()
        let helper = try #require(store.hostHelper)
        await helper.install()
        guard case .installed = helper.status else {
            Issue.record("Expected an installed Helper, read \(String(describing: helper.status))")
            return
        }
        #expect(helper.offersRemoval)

        await connector.setOutcome(.connectFails(.sshUnreachable(detail: "no route")))
        await store.runChecks()
        #expect(store.hostHelper === helper)
        #expect(helper.reading == .unavailable(message: Self.unreachableHint))
        #expect(helper.status == nil)
        #expect(!helper.offersRemoval)
    }

    @Test func aHostOutOfReachOnALaterCheckOffersNoInstall() async throws {
        let connector = reaching(ScriptedCoreHost(helper: ScriptedHelperHost(), channel: .refused))
        let store = coreStore(connector)
        await store.runChecks()
        let helper = try #require(store.hostHelper)
        #expect(helper.installAction == .install)
        #expect(helper.plan != nil)

        await connector.setOutcome(.connectFails(.sshUnreachable(detail: "no route")))
        await store.runChecks()
        #expect(helper.installAction == nil)
        #expect(helper.plan == nil)
    }

    @Test func aHostOutOfReachClearsTheLastActionsFailure() async throws {
        let scripted = ScriptedHelperHost()
        await scripted.configure {
            $0.lingerOn = false
            $0.lingerRefusal = "Interactive authentication required."
        }
        let connector = reaching(ScriptedCoreHost(helper: scripted, channel: .refused))
        let store = coreStore(connector)
        await store.runChecks()
        let helper = try #require(store.hostHelper)
        await helper.turnOnLinger()
        #expect(helper.failure != nil)

        await connector.setOutcome(.connectFails(.sshUnreachable(detail: "no route")))
        await store.runChecks()
        #expect(helper.failure == nil)
    }

    /// The preflight stops before it dials, so the Host's Helper goes unread.
    @Test func credentialsThatCannotLoadLeaveTheHelperUnread() async throws {
        let store = coreStore(
            reaching(ScriptedCoreHost(helper: ScriptedHelperHost(), channel: .refused)),
            authMethod: .password)
        let account = HostStore.passwordAccount(for: store.host.id)
        try secrets.write(Data("hunter2".utf8), account: account)
        await store.runChecks()
        let helper = try #require(store.hostHelper)
        #expect(helper.status == .notInstalled)

        try secrets.removeSecret(account: account)
        await store.runChecks()
        #expect(store.hostHelper === helper)
        #expect(
            helper.reading
                == .unavailable(message: "No password is saved for this Host. Edit the Host and enter one."))
    }

    @Test func aFirstCheckWithoutCredentialsStillShowsTheRow() async throws {
        let store = coreStore(
            reaching(ScriptedCoreHost(helper: ScriptedHelperHost(), channel: .refused)),
            authMethod: .password)
        await store.runChecks()
        #expect(store.hostHelper?.rowValue == "Unavailable")
    }

    @Test func aCancelledCheckStopsSayingItIsChecking() async throws {
        let store = coreStore(FakeTransportConnector(outcome: .hangs(.milliseconds(300))))
        let running = Task { await store.runChecks() }
        try await waitUntilRunning(store)
        #expect(store.hostHelper?.reading == .checking)

        store.cancelChecks()
        #expect(store.hostHelper?.reading == .unavailable(message: Self.cancelledHint))

        // The abandoned connect times out later; that is never shown.
        await running.value
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.hostHelper?.reading == .unavailable(message: Self.cancelledHint))
    }

    /// A check in flight has yet to say anything about the Host.
    @Test func aLaterCheckInFlightShowsNoEarlierReading() async throws {
        let connector = reaching(ScriptedCoreHost(helper: ScriptedHelperHost(), channel: .refused))
        let store = coreStore(connector)
        await store.runChecks()
        let helper = try #require(store.hostHelper)
        #expect(helper.status == .notInstalled)

        await connector.setOutcome(.hangs(.milliseconds(200)))
        let running = Task { await store.runChecks() }
        try await waitUntilRunning(store)
        #expect(helper.reading == .checking)
        #expect(helper.installAction == nil)
        await running.value
    }

    @Test func anActionFromHostDetailReachesWhatFollowsTheHelper() async throws {
        let core = ScriptedCoreHost(helper: ScriptedHelperHost(), channel: .refused)
        var heard = 0
        let store = HostOnboardingStore(
            host: Host(address: "box.example", username: "dev", serverKind: .herdrCore),
            connector: reaching(core),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: credentials,
            hostHelperDidChange: { heard += 1 })
        await store.runChecks()
        #expect(heard == 0)

        await store.hostHelper?.install()

        #expect(heard == 1)
    }

    @Test func aHerdrTUIHostHasNoHelper() async throws {
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrTUI)
        let store = HostOnboardingStore(
            host: host,
            connector: FakeTransportConnector(
                outcome: .connects(pingResult: .success(ServerInfo(version: "0", protocolVersion: 1)))),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: credentials)
        await store.runChecks()
        #expect(store.hostHelper == nil)
    }
}
