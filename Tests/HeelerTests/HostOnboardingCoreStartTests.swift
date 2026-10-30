import Foundation
import Testing

@testable import Heeler

/// The confirmed Start of a herdr-core Host, against a scripted exec that
/// records every command: only this action may run anything but the locator.
@MainActor
@Suite("Core Start in Host detail and onboarding")
struct HostOnboardingCoreStartTests {
    private static let notRunningMessage = TransportError.herdrCoreNotRunning(
        socketPath: ScriptedCoreHost.socketPath, socketFilePresent: false
    ).presentation.message

    private func makeStore(
        _ core: ScriptedCoreHost, session: String = "work", kind: ServerKind = .herdrCore,
        connectorOutcome: FakeTransportConnector.Outcome = .connects(
            pingResult: .success(ServerInfo(version: "0.7.5", protocolVersion: 17)))
    ) -> (HostOnboardingStore, HostStore) {
        let host = Host(address: "box.example", username: "dev", serverKind: kind, sessionName: session)
        let store = HostOnboardingStore(
            host: host,
            connector: FakeTransportConnector(outcome: connectorOutcome, core: core),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            offersHerdrCore: true)
        return (store, HostStore(volatileHosts: [host]))
    }

    /// A Host that read not running, with the Start already confirmed.
    private func started(
        _ core: ScriptedCoreHost, session: String = "work"
    ) async -> HostOnboardingStore {
        let (store, _) = makeStore(core, session: session)
        await store.runChecks()
        store.requestCoreStart()
        await store.confirmCoreStart()
        return store
    }

    private func expectOnlyLocators(_ core: ScriptedCoreHost, sourceLocation: SourceLocation = #_sourceLocation) async {
        let log = await core.log
        #expect(!log.contains("start"), sourceLocation: sourceLocation)
        for script in await core.scripts {
            #expect(!script.contains("server"), sourceLocation: sourceLocation)
            #expect(!script.contains(" start"), sourceLocation: sourceLocation)
        }
    }

    // MARK: What a Host offers

    @Test func aLinuxHostThatReadsNotRunningOffersStartInHostDetail() async {
        let core = ScriptedCoreHost(channel: .refused)
        let (store, _) = makeStore(core)

        await store.runChecks()

        #expect(store.report?[.serverRunning] == .failed(hint: Self.notRunningMessage))
        #expect(store.coreStartOffer == .start)
        #expect(await core.log == ["locator", "open \(ScriptedCoreHost.socketPath)", "close"])
    }

    @Test func aLinuxHostThatReadsNotRunningOffersStartInOnboarding() async {
        let core = ScriptedCoreHost(channel: .refused)
        let (store, catalog) = makeStore(core, kind: .unconfirmed)

        await store.runChecks()
        #expect(store.coreStartOffer == nil)
        await store.confirmServerKind(.herdrCore, in: catalog)

        #expect(store.coreStartOffer == .start)
        await expectOnlyLocators(core)
    }

    @Test func aMacOSHostShowsInstructionsNamingThePathAndTheSessionInstead() async {
        let core = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(
                executable: "/Users/me/.local/bin/herdr-core", kernel: "Darwin", shell: "/bin/zsh"),
            channel: .refused)
        let (store, _) = makeStore(core, session: "phone")

        await store.runChecks()

        guard case .instructions(let command) = store.coreStartOffer else {
            Issue.record("A macOS Host offers instructions, got \(String(describing: store.coreStartOffer))")
            return
        }
        #expect(command == "HC_SESSION=phone /Users/me/.local/bin/herdr-core server start")
        let explanation = store.coreStartOffer?.explanation ?? ""
        #expect(explanation.contains("desktop login session"))

        store.requestCoreStart()
        #expect(store.coreStartConfirmation == nil)
        await store.confirmCoreStart()
        await expectOnlyLocators(core)
    }

    @Test func nothingIsOfferedWhenTheHostDoesNotReadNotRunning() async {
        let cases: [ScriptedCoreHost] = [
            ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply())),
            ScriptedCoreHost(locator: ScriptedCoreHost.locatorLines(executable: nil), channel: .refused),
            ScriptedCoreHost(channel: .answersHello(ScriptedCoreHost.helloReply(features: ["framed"]))),
        ]
        for core in cases {
            let (store, _) = makeStore(core)
            await store.runChecks()
            #expect(store.coreStartOffer == nil)
            store.requestCoreStart()
            #expect(store.coreStartConfirmation == nil)
            await expectOnlyLocators(core)
        }
    }

    @Test func aHerdrTUIHostIsOfferedNothing() async {
        let core = ScriptedCoreHost(channel: .refused)
        let (store, _) = makeStore(core, kind: .herdrTUI)

        await store.runChecks()

        #expect(store.coreStartOffer == nil)
        #expect(await core.log.isEmpty)
    }

    // MARK: Nothing runs before the user confirms

    @Test func aRequestAloneRunsNothingAndNamesWhatItWillStart() async throws {
        let core = ScriptedCoreHost(channel: .refused)
        let (store, _) = makeStore(core, session: "  work team ")
        await store.runChecks()
        let before = await core.log

        store.requestCoreStart()

        let confirmation = try #require(store.coreStartConfirmation)
        #expect(confirmation.session == "work team")
        #expect(confirmation.message.contains("\"work team\""))
        #expect(confirmation.message.contains("interactive login shell"))
        #expect(confirmation.message.contains("environment of your own terminal"))
        #expect(confirmation.message.contains("systemd linger"))
        #expect(confirmation.message.contains("when it is off"))
        #expect(await core.log == before)
        await expectOnlyLocators(core)
    }

    @Test func cancellingRunsNothing() async {
        let core = ScriptedCoreHost(channel: .refused)
        let (store, _) = makeStore(core)
        await store.runChecks()
        let before = await core.log

        store.requestCoreStart()
        store.cancelCoreStart()

        #expect(store.coreStartConfirmation == nil)
        #expect(store.coreStartOffer == .start)
        await store.confirmCoreStart()
        #expect(await core.log == before)
    }

    @Test func aConfirmationWithoutARequestRunsNothing() async {
        let core = ScriptedCoreHost(channel: .refused)
        let (store, _) = makeStore(core)
        await store.runChecks()
        let before = await core.log

        await store.confirmCoreStart()

        #expect(await core.log == before)
    }

    /// Retries and reconnects are preflight runs. Only the locator goes out.
    @Test func repeatedRetriesOfANotRunningHostOnlyEverRunTheLocator() async {
        let detail = ScriptedCoreHost(channel: .refused)
        let (store, _) = makeStore(detail)
        for _ in 0..<4 { await store.runChecks() }
        #expect(await detail.log.filter { $0 == "locator" }.count == 4)
        #expect(await detail.scripts.count == 4)
        await expectOnlyLocators(detail)

        let onboarding = ScriptedCoreHost(channel: .refused)
        let (added, catalog) = makeStore(onboarding, kind: .unconfirmed)
        await added.runChecks()
        await added.confirmServerKind(.herdrCore, in: catalog)
        for _ in 0..<4 { await added.runChecks() }
        #expect(await onboarding.log.filter { $0 == "locator" }.count == 5)
        await expectOnlyLocators(onboarding)
    }

    // MARK: The confirmed Start

    @Test func aFreshStartRunsThePreflightAgainAndTheHostReadsRunning() async throws {
        let core = ScriptedCoreHost(
            channelAfterStart: .answersHello(ScriptedCoreHost.helloReply()), channel: .refused)

        let store = await started(core)

        let socket = "open \(ScriptedCoreHost.socketPath)"
        #expect(await core.log == [
            "locator", socket, "close",
            "locator", "start", "close",
            "locator", socket, "close",
        ])
        #expect(store.report == .allPassed)
        #expect(store.serverKindSummary == "herdr-core 0.1.13")
        #expect(store.coreStartOffer == nil)
        #expect(store.coreStart == .started(session: "work"))
        #expect(store.coreStart.note?.contains("environment") == true)
        let script = try #require(await core.scripts.first { $0.contains("server start") })
        #expect(script.contains("HC_SESSION="))
        #expect(script.contains(ScriptedCoreHost.installedPath))
    }

    @Test func theStartCarriesTheHostsNormalizedSession() async throws {
        let core = ScriptedCoreHost(
            channelAfterStart: .answersHello(ScriptedCoreHost.helloReply()), channel: .refused)

        _ = await started(core, session: " it's work ")

        let script = try #require(await core.scripts.first { $0.contains("server start") })
        let expected = String(
            decoding: try HerdrCoreStart.script(
                executablePath: ScriptedCoreHost.installedPath, session: "it's work"),
            as: UTF8.self)
        #expect(script == expected)
    }

    @Test func aCoreAlreadyRunningPromisesNoEnvironment() async {
        let core = ScriptedCoreHost(
            start: .alreadyRunning, channelAfterStart: .answersHello(ScriptedCoreHost.helloReply()),
            channel: .refused)

        let store = await started(core)

        #expect(store.coreStart == .alreadyRunning(session: "work"))
        #expect(store.report == .allPassed)
        let note = store.coreStart.note ?? ""
        #expect(note.contains("already running"))
        #expect(note.contains("changed nothing"))
        #expect(!note.contains("login shell"))
        #expect(!note.contains("your terminal"))
    }

    @Test func aCoreAlreadyRunningBehindARefusedChannelShowsOnlyForwarding() async {
        let core = ScriptedCoreHost(
            locator: ScriptedCoreHost.locatorLines(socketFile: true), start: .alreadyRunning, channel: .refused)
        let (store, _) = makeStore(core)
        await store.runChecks()
        guard case .failed(let before) = store.report?[.serverRunning] else {
            Issue.record("A refused channel should fail its check")
            return
        }
        #expect(before.contains("stopped or crashed"))

        store.requestCoreStart()
        await store.confirmCoreStart()

        #expect(store.coreStart == .alreadyRunning(session: "work"))
        guard case .failed(let hint) = store.report?[.serverRunning] else {
            Issue.record("A refused channel should still fail its check")
            return
        }
        #expect(hint.contains("refuses socket forwarding"))
        #expect(!hint.contains("not running"))
        #expect(!hint.contains("stopped or crashed"))
        // Another Start would say the same.
        #expect(store.coreStartOffer == nil)
    }

    @Test func aFreshCoreBehindARefusedChannelShowsOnlyForwardingToo() async {
        let core = ScriptedCoreHost(channel: .refused)

        let store = await started(core)

        #expect(store.coreStart == .started(session: "work"))
        guard case .failed(let hint) = store.report?[.serverRunning] else {
            Issue.record("A refused channel should still fail its check")
            return
        }
        #expect(hint.contains("refuses socket forwarding"))
        #expect(!hint.contains("not running"))
    }

    /// The narrowed copy holds for the run that follows a Start. A later run
    /// knows nothing about the core and goes back to reading the Host.
    @Test func aLaterRunReadsNotRunningAgain() async {
        let core = ScriptedCoreHost(start: .alreadyRunning, channel: .refused)
        let store = await started(core)
        #expect(store.coreStart == .alreadyRunning(session: "work"))

        await store.runChecks()

        #expect(store.report?[.serverRunning] == .failed(hint: Self.notRunningMessage))
        #expect(store.coreStartOffer == .start)
        #expect(store.coreStart == .idle)
    }

    @Test func aFailedStartSaysWhyAndStaysOnOffer() async {
        let core = ScriptedCoreHost(
            start: .exits(status: 1, stdout: "", stderr: "bash: no job control\ndisk full\n"),
            channel: .refused)

        let store = await started(core)

        #expect(store.coreStart == .failed(message: "herdr-core did not start: disk full."))
        #expect(store.report?[.serverRunning] == .failed(hint: Self.notRunningMessage))
        #expect(store.coreStartOffer == .start)
        // A failure runs no second preflight.
        #expect(await core.log.last == "close")
        #expect(await core.log.filter { $0 == "locator" }.count == 2)
    }

    @Test func aStartWithNoDetailStillSaysItFailed() async {
        let core = ScriptedCoreHost(start: .exits(status: 1, stdout: "", stderr: ""), channel: .refused)

        let store = await started(core)

        #expect(store.coreStart == .failed(message: "herdr-core did not start."))
    }

    @Test func aStartThatTimesOutPointsAtTheStartupFiles() async {
        let core = ScriptedCoreHost(start: .throwsError(.timedOut), channel: .refused)

        let store = await started(core)

        guard case .failed(let message) = store.coreStart else {
            Issue.record("A timed-out Start should read as failed, got \(store.coreStart)")
            return
        }
        #expect(message.contains("did not finish"))
        #expect(message.contains("Run the checks again"))
    }

    @Test func aStartOverALostConnectionSaysSo() async {
        let core = ScriptedCoreHost(start: .throwsError(.sshUnreachable(detail: "gone")), channel: .refused)

        let store = await started(core)

        guard case .failed(let message) = store.coreStart else {
            Issue.record("A lost connection should read as failed, got \(store.coreStart)")
            return
        }
        #expect(message.hasPrefix("herdr-core did not start:"))
    }
}
