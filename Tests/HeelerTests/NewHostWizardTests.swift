import Foundation
import Testing

@testable import Heeler

/// Add Host with everything it touches, each a stand-in the test can read.
@MainActor
private struct WizardRig {
    let wizard: NewHostWizard
    let catalog: HostStore
    let knownHosts: InMemoryKnownHostsStore
    let connector: FakeTransportConnector
    let switcher: HostServerSwitch
    let discoveries = HostServerDiscoveryStore(defaults: nil)

    func finish() async -> Host.ID? {
        await wizard.finish(switcher: switcher, discoveries: discoveries)
    }

    /// The key trusted under a record's id, which may be one no record has yet.
    func trustedKey(for id: Host.ID) async -> HostKeyFingerprint? {
        let key = HostKeyTrust.hostKey(id)
        return await knownHosts.fingerprint(host: key.host, port: key.port)
    }

    /// The Servers that are on, across the catalog, in its order.
    var serversOn: [HostServerKey] { catalog.hosts.compactMap(\.serverKey) }
}

@MainActor
@Suite("New Host wizard")
struct NewHostWizardTests {
    private static let sessionsJSON = #"{"sessions":[{"name":"default","default":true,"running":true}]}"#
    private static let tmuxPath = "/home/dev/.local/bin/tmux"
    private static let tui = HostServerKey(kind: .herdrTUI, name: "")
    private static let core = HostServerKey(kind: .herdrCore, name: "")
    private static let tmux = HostServerKey(kind: .tmux, name: "")
    private static let workTmux = HostServerKey(kind: .tmux, name: "work")
    private let keyBlob = Data("fake-host-key".utf8)
    private var hostKey: HostKeyFingerprint { HostKeyFingerprint(publicKeyBlob: keyBlob) }

    /// A Host that runs Herdr TUI and tmux on two sockets, with a core that is
    /// installed and not running.
    private static func machine() -> ScriptedCoreHost {
        ScriptedCoreHost(
            herdrRead: .answers(sessionsJSON),
            tmuxProbe: ScriptedCoreHost.tmuxLines(executable: tmuxPath, sockets: ["default", "work"]),
            channel: .refused)
    }

    private func makeRig(
        catalog: HostStore = HostStore(volatileHosts: []),
        outcome: FakeTransportConnector.Outcome = .connects(pingResult: .failure(.cancelled)),
        presentedKeyBlob: Data? = nil,
        presentedJumpKeyBlob: Data? = nil,
        knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore()
    ) -> WizardRig {
        let connector = FakeTransportConnector(
            outcome: outcome, presentedKeyBlob: presentedKeyBlob,
            presentedJumpKeyBlob: presentedJumpKeyBlob, core: Self.machine())
        let dependencies = HostOnboardingDependencies(
            connector: connector,
            knownHosts: knownHosts,
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()))
        return WizardRig(
            wizard: NewHostWizard(catalog: catalog, dependencies: dependencies),
            catalog: catalog, knownHosts: knownHosts, connector: connector,
            switcher: HostServerSwitch(catalog: catalog, dependencies: dependencies))
    }

    /// What the first step's form holds once the user has typed a Host in.
    private func fill(_ wizard: NewHostWizard, address: String = "studio.example") {
        wizard.draft.name = "Studio"
        wizard.draft.address = address
        wizard.draft.username = "dev"
    }

    /// Polls until `condition` holds, yielding the main actor so the wizard's
    /// look can progress in between.
    private func waitUntil(_ comment: Comment, condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), comment)
    }

    /// Connects a Host whose key is new, trusting it when asked.
    private func connectTrustingTheKey(_ wizard: NewHostWizard) async throws {
        let connecting = Task { await wizard.connect() }
        try await waitUntil("the key is asked about") { wizard.scanner.pendingFingerprint != nil }
        wizard.trust()
        await connecting.value
    }

    // MARK: Connecting

    @Test func theFormConnectsOnlyOnceItNamesAHost() {
        let wizard = makeRig().wizard
        #expect(wizard.step == .connect)
        #expect(!wizard.canConnect)

        fill(wizard)

        #expect(wizard.canConnect)
        #expect(wizard.address == "studio.example")
    }

    /// Nothing reaches the catalog before the last step.
    @Test func connectingLandsOnTheServersWithTheRunningOnesChecked() async throws {
        let rig = makeRig()
        fill(rig.wizard)

        await rig.wizard.connect()

        #expect(rig.wizard.step == .servers)
        #expect(rig.wizard.scan?.servers.map(\.key) == [Self.tui, Self.core, Self.tmux, Self.workTmux])
        #expect(rig.wizard.checked == [Self.tui, Self.tmux, Self.workTmux])
        #expect(rig.wizard.checkedCount == 3)
        #expect(rig.wizard.failure == nil)
        #expect(rig.wizard.existing == nil)
        #expect(rig.catalog.hosts.isEmpty)
        #expect(await rig.connector.transports.isEmpty)
    }

    @Test func aHostThatCouldNotBeReachedSaysWhyOnTheFirstStep() async throws {
        let error = TransportError.sshUnreachable(detail: "refused")
        let rig = makeRig(outcome: .connectFails(error))
        fill(rig.wizard)

        await rig.wizard.connect()

        #expect(rig.wizard.step == .connect)
        #expect(rig.wizard.scan == nil)
        #expect(rig.wizard.failure?.summary == error.presentation.summary)
        #expect(rig.wizard.canConnect)
    }

    // MARK: Trusting the key

    @Test func aKeySeenForTheFirstTimeIsShownOnTheSecondStepUntilTheLookEnds() async throws {
        let rig = makeRig(presentedKeyBlob: keyBlob)
        let wizard = rig.wizard
        fill(wizard)

        let connecting = Task { await wizard.connect() }
        try await waitUntil("the key is asked about") { wizard.scanner.pendingFingerprint != nil }
        let shown = HostKeyCandidate(host: "studio.example", port: 22, fingerprint: hostKey)
        #expect(wizard.step == .trust)
        #expect(wizard.candidate == shown)
        #expect(!wizard.isLookingAfterTrust)
        #expect(!wizard.isConnecting)

        wizard.trust()
        // The key stays up while the look goes on.
        #expect(wizard.step == .trust)
        #expect(wizard.candidate == shown)
        #expect(wizard.isLookingAfterTrust)

        await connecting.value
        #expect(wizard.step == .servers)
        #expect(!wizard.isLookingAfterTrust)
        // Trusted under the id the Host's first record takes, before any exists.
        #expect(await rig.trustedKey(for: wizard.recordID) == hostKey)
        #expect(rig.catalog.hosts.isEmpty)
    }

    /// A Route through a Jump Host shows two keys, one after the other, and
    /// each waits for its own answer.
    @Test func aRouteThroughAJumpHostAsksAboutBothKeysInTurn() async throws {
        let jumpBlob = Data("fake-jump-key".utf8)
        let rig = makeRig(presentedKeyBlob: keyBlob, presentedJumpKeyBlob: jumpBlob)
        let wizard = rig.wizard
        fill(wizard)
        wizard.draft.routes[0].jumpAddress = "vps.example"

        let connecting = Task { await wizard.connect() }
        try await waitUntil("the Jump Host's key is asked about") { wizard.scanner.pendingFingerprint != nil }
        let first = try #require(wizard.candidate)
        #expect(
            first
                == HostKeyCandidate(
                    host: "vps.example", port: 22, fingerprint: HostKeyFingerprint(publicKeyBlob: jumpBlob)))
        #expect(wizard.step == .trust)

        wizard.trust()
        try await waitUntil("the Host's own key is asked about next") { wizard.scanner.pendingFingerprint != nil }
        let second = try #require(wizard.candidate)
        #expect(second == HostKeyCandidate(host: "studio.example", port: 22, fingerprint: hostKey))
        #expect(second != first)
        #expect(wizard.step == .trust)
        // The second key is a question, not a look under way.
        #expect(!wizard.isLookingAfterTrust)

        wizard.trust()
        #expect(wizard.isLookingAfterTrust)
        await connecting.value

        #expect(wizard.step == .servers)
        #expect(!wizard.isLookingAfterTrust)
        #expect(
            await rig.knownHosts.fingerprint(host: "vps.example", port: 22)
                == HostKeyFingerprint(publicKeyBlob: jumpBlob))
        #expect(await rig.trustedKey(for: wizard.recordID) == hostKey)
    }

    @Test func decliningTheKeyGoesBackToTheFormWithNothingToReport() async throws {
        let rig = makeRig(presentedKeyBlob: keyBlob)
        let wizard = rig.wizard
        fill(wizard)
        let connecting = Task { await wizard.connect() }
        try await waitUntil("the key is asked about") { wizard.scanner.pendingFingerprint != nil }

        wizard.declineTrust()
        await connecting.value

        #expect(wizard.step == .connect)
        #expect(wizard.failure == nil)
        #expect(wizard.candidate == nil)
        #expect(await rig.trustedKey(for: wizard.recordID) == nil)
    }

    /// Declining a Jump Host's key is the same answer, one hop earlier.
    @Test func decliningAJumpHostsKeyGoesBackToTheFormToo() async throws {
        let rig = makeRig(presentedKeyBlob: keyBlob, presentedJumpKeyBlob: Data("fake-jump-key".utf8))
        let wizard = rig.wizard
        fill(wizard)
        wizard.draft.routes[0].jumpAddress = "vps.example"
        let connecting = Task { await wizard.connect() }
        try await waitUntil("the Jump Host's key is asked about") { wizard.scanner.pendingFingerprint != nil }

        wizard.declineTrust()
        await connecting.value

        #expect(wizard.step == .connect)
        #expect(wizard.failure == nil)
        #expect(await rig.knownHosts.fingerprint(host: "vps.example", port: 22) == nil)
    }

    @Test func goingBackFromTheKeyEndsTheAttempt() async throws {
        let rig = makeRig(presentedKeyBlob: keyBlob)
        let wizard = rig.wizard
        fill(wizard)
        let connecting = Task { await wizard.connect() }
        try await waitUntil("the key is asked about") { wizard.scanner.pendingFingerprint != nil }

        wizard.backToConnect()

        #expect(wizard.step == .connect)
        await connecting.value
        #expect(wizard.step == .connect)
        #expect(wizard.failure == nil)
        #expect(wizard.canConnect)
        #expect(await rig.trustedKey(for: wizard.recordID) == nil)
    }

    @Test func connectingAgainByTheSameRoutesDoesNotAskTwice() async throws {
        let rig = makeRig(presentedKeyBlob: keyBlob)
        fill(rig.wizard)
        try await connectTrustingTheKey(rig.wizard)
        rig.wizard.backToConnect()

        await rig.wizard.connect()

        #expect(rig.wizard.step == .servers)
    }

    /// A key trusted on an earlier attempt belongs to the machine those routes
    /// reached, which edited routes may no longer name.
    @Test func aKeyTrustedForOtherRoutesIsAskedAboutAgain() async throws {
        let rig = makeRig(presentedKeyBlob: keyBlob)
        let wizard = rig.wizard
        fill(wizard)
        try await connectTrustingTheKey(wizard)
        wizard.backToConnect()

        wizard.draft.address = "other.example"
        let connecting = Task { await wizard.connect() }
        try await waitUntil("the key is asked about again") { wizard.scanner.pendingFingerprint != nil }

        #expect(wizard.candidate == HostKeyCandidate(host: "other.example", port: 22, fingerprint: hostKey))
        wizard.declineTrust()
        await connecting.value
        #expect(await rig.trustedKey(for: wizard.recordID) == nil)
    }

    // MARK: Saving

    @Test func finishingAddsOneHostWithTheCheckedServersOn() async throws {
        let rig = makeRig()
        fill(rig.wizard)
        await rig.wizard.connect()
        let scan = try #require(rig.wizard.scan)

        let saved = await rig.finish()

        #expect(saved == rig.wizard.recordID)
        #expect(rig.wizard.saveFailure == nil)
        let host = try #require(rig.catalog.machines.first)
        #expect(rig.catalog.machines.count == 1)
        #expect(host.name == "Studio")
        #expect(host.servers.compactMap(\.serverKey) == [Self.tui, Self.tmux, Self.workTmux])
        #expect(host.spareRecord == nil)
        // The record that held the Host became its first Server.
        #expect(host.record(of: Self.tui)?.id == rig.wizard.recordID)
        // A tmux Server keeps the paths the look just resolved.
        #expect(
            host.record(of: Self.workTmux)?.tmuxPaths
                == TmuxPaths(executable: Self.tmuxPath, socket: "/tmp/tmux-1000/work"))
        // The user watched this look: nothing it found is news afterwards.
        #expect(rig.discoveries.found(on: host.id) == scan.servers)
        #expect(rig.discoveries.unseen(on: host).isEmpty)
    }

    @Test func aServerLeftUncheckedStaysOffAndIsNotPointedOutAgain() async throws {
        let rig = makeRig()
        fill(rig.wizard)
        await rig.wizard.connect()

        rig.wizard.checked = [Self.workTmux]
        #expect(rig.wizard.checkedCount == 1)
        _ = await rig.finish()

        let host = try #require(rig.catalog.machines.first)
        #expect(rig.serversOn == [Self.workTmux])
        #expect(rig.catalog.hosts.map(\.id) == [rig.wizard.recordID])
        #expect(rig.discoveries.unseen(on: host).isEmpty)
    }

    /// A Server that is installed and not running can be checked by hand: its
    /// record connects once the user starts it.
    @Test func aServerThatIsNotRunningIsTurnedOnWhenChecked() async throws {
        let rig = makeRig()
        fill(rig.wizard)
        await rig.wizard.connect()

        rig.wizard.checked = [Self.core]
        _ = await rig.finish()

        #expect(rig.serversOn == [Self.core])
    }

    @Test func savingWithoutConnectingAddsAHostWithNoServer() async throws {
        let rig = makeRig()
        fill(rig.wizard)

        let saved = await rig.finish()

        #expect(saved == rig.wizard.recordID)
        #expect(rig.catalog.hosts.map(\.id) == [rig.wizard.recordID])
        #expect(rig.catalog.hosts.first?.serverKind == .unconfirmed)
        let host = try #require(rig.catalog.machines.first)
        #expect(host.servers.isEmpty)
        #expect(host.name == "Studio")
        #expect(rig.discoveries.found(on: host.id).isEmpty)
        #expect(await rig.connector.capturedSettings.isEmpty)
    }

    @Test func aHostThatCouldNotBeReachedCanStillBeSaved() async throws {
        let rig = makeRig(outcome: .connectFails(.sshUnreachable(detail: "refused")))
        fill(rig.wizard)
        await rig.wizard.connect()

        let saved = await rig.finish()

        #expect(saved == rig.wizard.recordID)
        #expect(rig.catalog.machines.first?.servers.isEmpty == true)
    }

    @Test func aFormThatNamesNoHostSavesNothing() async throws {
        let rig = makeRig()

        #expect(await rig.finish() == nil)
        #expect(rig.catalog.hosts.isEmpty)
    }

    @Test func aPasswordHostKeepsItsPasswordOnEveryRecord() async throws {
        let rig = makeRig()
        fill(rig.wizard)
        rig.wizard.draft.authMethod = .password
        #expect(!rig.wizard.canConnect)
        rig.wizard.draft.password = "hunter2"

        await rig.wizard.connect()
        _ = await rig.finish()

        #expect(rig.catalog.hosts.count == 3)
        for record in rig.catalog.hosts {
            #expect(try rig.catalog.password(for: record) == "hunter2")
        }
    }

    /// The Host is saved, the Server the catalog would not take is not, and
    /// the user is told which.
    @Test func aServerTheCatalogRefusesStopsThereAndSaysWhy() async throws {
        let suiteName = "NewHostWizardTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("{not json".utf8), forKey: "tmuxHosts")
        let rig = makeRig(catalog: HostStore(defaults: defaults, secrets: InMemorySecretStore()))
        fill(rig.wizard)
        await rig.wizard.connect()

        let saved = await rig.finish()

        #expect(saved == rig.wizard.recordID)
        #expect(rig.serversOn == [Self.tui])
        #expect(
            rig.wizard.saveFailure == "The saved tmux Hosts could not be read, so no tmux Host can be added.")

        rig.wizard.dismissSaveFailure()
        #expect(rig.wizard.saveFailure == nil)
    }

    // MARK: A Host that is in the catalog already

    /// Adding the same connection again turns Servers on there. Its key was
    /// trusted when it was added, so it is not asked about twice.
    @Test func aConnectionInTheCatalogTakesTheServersInsteadOfASecondHost() async throws {
        let existing = Host(name: "Studio", address: "studio.example", username: "dev")
        let knownHosts = InMemoryKnownHostsStore()
        let trust = HostKeyTrust.hostKey(existing.id)
        await knownHosts.setFingerprint(hostKey, host: trust.host, port: trust.port)
        let rig = makeRig(
            catalog: HostStore(volatileHosts: [existing]), presentedKeyBlob: keyBlob, knownHosts: knownHosts)
        fill(rig.wizard)
        #expect(rig.wizard.existing?.members.map(\.id) == [existing.id])

        await rig.wizard.connect()

        #expect(rig.wizard.step == .servers)
        #expect(rig.wizard.isAlreadyOn(Self.tui))
        #expect(!rig.wizard.isAlreadyOn(Self.tmux))
        // Herdr TUI is on already: finishing turns on the two that are not.
        #expect(rig.wizard.checkedCount == 2)

        let saved = await rig.finish()

        #expect(saved == existing.id)
        #expect(rig.catalog.machines.count == 1)
        #expect(rig.serversOn == [Self.tui, Self.tmux, Self.workTmux])
        #expect(!rig.catalog.hosts.contains { $0.id == rig.wizard.recordID })
        for record in rig.catalog.hosts {
            #expect(await rig.trustedKey(for: record.id) == hostKey)
        }

        // The wizard's own id never became a record, so its copy of the trust goes.
        await rig.wizard.close()
        #expect(await rig.trustedKey(for: rig.wizard.recordID) == nil)
        #expect(await rig.trustedKey(for: existing.id) == hostKey)
    }

    /// The trust the catalog Host has is the one that counts: a key that
    /// changed since is refused, not offered as if it were new.
    @Test func aCatalogHostWhoseKeyChangedIsRefusedInsteadOfAskedAbout() async throws {
        let existing = Host(name: "Studio", address: "studio.example", username: "dev")
        let knownHosts = InMemoryKnownHostsStore()
        let known = HostKeyFingerprint(publicKeyBlob: Data("old-host-key".utf8))
        let trust = HostKeyTrust.hostKey(existing.id)
        await knownHosts.setFingerprint(known, host: trust.host, port: trust.port)
        let rig = makeRig(
            catalog: HostStore(volatileHosts: [existing]), presentedKeyBlob: keyBlob, knownHosts: knownHosts)
        fill(rig.wizard)

        await rig.wizard.connect()

        #expect(rig.wizard.step == .connect)
        #expect(rig.wizard.failure != nil)
        #expect(
            rig.wizard.scanner.pendingHostKeyReplacement == HostKeyReplacement(known: known, presented: hostKey))
    }

    // MARK: Looking again

    @Test func lookingAgainKeepsWhatTheUserUnchecked() async throws {
        let rig = makeRig()
        fill(rig.wizard)
        await rig.wizard.connect()
        rig.wizard.checked.remove(Self.workTmux)

        await rig.wizard.scanAgain()

        #expect(rig.wizard.step == .servers)
        #expect(!rig.wizard.isScanningAgain)
        #expect(rig.wizard.checked == [Self.tui, Self.tmux])
    }

    @Test func aHostThatNoLongerAnswersGoesBackToTheFirstStepToSayWhy() async throws {
        let rig = makeRig()
        fill(rig.wizard)
        await rig.wizard.connect()
        let error = TransportError.sshUnreachable(detail: "refused")
        await rig.connector.setOutcome(.connectFails(error))

        await rig.wizard.scanAgain()

        #expect(rig.wizard.step == .connect)
        #expect(rig.wizard.failure?.summary == error.presentation.summary)
    }

    // MARK: Closing

    @Test func closingForgetsTheKeyOfAHostThatWasNeverSaved() async throws {
        let rig = makeRig(presentedKeyBlob: keyBlob)
        fill(rig.wizard)
        try await connectTrustingTheKey(rig.wizard)
        #expect(await rig.trustedKey(for: rig.wizard.recordID) == hostKey)

        await rig.wizard.close()

        #expect(await rig.trustedKey(for: rig.wizard.recordID) == nil)
        #expect(rig.catalog.hosts.isEmpty)
    }

    @Test func closingKeepsTheKeyOfAHostThatWasSaved() async throws {
        let rig = makeRig(presentedKeyBlob: keyBlob)
        fill(rig.wizard)
        try await connectTrustingTheKey(rig.wizard)
        _ = await rig.finish()

        await rig.wizard.close()

        #expect(rig.catalog.hosts.count == 3)
        for record in rig.catalog.hosts {
            #expect(await rig.trustedKey(for: record.id) == hostKey)
        }
    }

    @Test func closingWhileTheKeyIsUpDeclinesIt() async throws {
        let rig = makeRig(presentedKeyBlob: keyBlob)
        fill(rig.wizard)
        let connecting = Task { await rig.wizard.connect() }
        try await waitUntil("the key is asked about") { rig.wizard.scanner.pendingFingerprint != nil }

        await rig.wizard.close()
        await connecting.value

        #expect(rig.wizard.scanner.pendingFingerprint == nil)
        #expect(await rig.trustedKey(for: rig.wizard.recordID) == nil)
    }
}
