import Foundation
import Observation

/// Adding a Host (ADR 0047): connect, trust its key, choose which of its
/// Servers to turn on. Nothing reaches the catalog before the last step, so a
/// Host that could not be reached leaves no half-made entry unless the user
/// asks for one.
@MainActor
@Observable
final class NewHostWizard {
    enum Step: Int, Equatable, CaseIterable {
        case connect, trust, servers
    }

    var draft: HostDraft
    /// The Servers checked on the last step.
    var checked: Set<HostServerKey> = []
    /// What the Host was found to run, once reached.
    private(set) var scan: HostServerScan?
    /// Why the last attempt did not get to the Servers, shown on the first step.
    private(set) var failure: HostServerScanner.Failure?
    /// The key just trusted, kept on the second step while the look goes on.
    private var trustedCandidate: HostKeyCandidate?
    /// The user trusted a key on this attempt.
    private var didTrust = false
    /// The last step is looking again.
    private(set) var isScanningAgain = false
    private(set) var isSaving = false
    /// Why saving stopped, for an alert.
    private(set) var saveFailure: String?
    let scanner: HostServerScanner

    /// The id the Host's first record takes: its key is trusted under it from
    /// the second step on, before any record exists.
    @ObservationIgnored let recordID = UUID()
    @ObservationIgnored private let catalog: HostStore
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private var didSave = false
    /// The routes the last attempt dialled.
    @ObservationIgnored private var attemptedRoutes: [HostMachine.Connection.Route]?
    /// The key a Pairing Code pinned for the Host, until the first look
    /// trusts it.
    @ObservationIgnored private var pairedFingerprint: HostKeyFingerprint?
    /// The key trusted under `recordID` is the one a Pairing Code pinned, which
    /// counts for more than one a Host in the catalog trusted before (ADR 0057).
    @ObservationIgnored private var trustsPairingCode = false
    /// The Host in the catalog trusts another key than the one the Pairing
    /// Code pinned and the look just met: finishing replaces it.
    private(set) var replacesTrustedKey = false
    /// A Pairing Code shown inside Herdr TUI vouches for one on the Host it
    /// named, whatever a look finds there.
    @ObservationIgnored private var runsHerdrTUI = false

    init(
        catalog: HostStore, dependencies: HostOnboardingDependencies = HostOnboardingDependencies(),
        prefill: HostDraft? = nil
    ) {
        var draft = prefill ?? HostDraft()
        // The first step edits the primary route in place.
        if draft.routes.isEmpty { draft.routes = [HostRouteDraft()] }
        self.draft = draft
        self.catalog = catalog
        scanner = HostServerScanner(dependencies: dependencies)
        knownHosts = dependencies.knownHosts
    }

    /// Add Host for a machine a Pairing Code just enrolled this device on
    /// (ADR 0057): the form is what the ceremony proved, and `connect()`
    /// trusts the key the code pinned, so it lands on the Servers unasked.
    convenience init(
        catalog: HostStore, dependencies: HostOnboardingDependencies = HostOnboardingDependencies(),
        paired machine: PairedMachine
    ) {
        var draft = HostDraft()
        draft.username = machine.username
        draft.authMethod = .deviceKey
        draft.routes = machine.addresses.map { address in
            var route = HostRouteDraft()
            route.address = address
            route.port = String(machine.port)
            return route
        }
        self.init(catalog: catalog, dependencies: dependencies, prefill: draft)
        pairedFingerprint = machine.hostKeyFingerprint
        runsHerdrTUI = machine.runsHerdrTUI
    }

    var step: Step {
        if scan != nil { return .servers }
        if scanner.pendingFingerprint != nil || didTrust { return .trust }
        return .connect
    }

    /// A key was trusted and the look goes on. Not while it asks about another:
    /// a Route through a Jump Host shows two keys, one after the other.
    var isLookingAfterTrust: Bool { didTrust && scanner.pendingFingerprint == nil }

    /// Dialing, before any key has been shown.
    var isConnecting: Bool { step == .connect && scanner.isLooking }

    var canConnect: Bool { draft.canSave(editing: nil) && !scanner.isLooking }

    /// The address the Host is being added by, for titles.
    var address: String { draft.address.trimmingCharacters(in: .whitespaces) }

    /// The Host already in the catalog under the connection being added. The
    /// last step turns Servers on there instead of adding a second entry.
    var existing: HostMachine? {
        guard let host = draft.makeHost(id: recordID) else { return nil }
        let connection = HostMachine.Connection(host)
        return catalog.machines.first { $0.id == connection }
    }

    /// Whether `server` is on already, on the Host that is in the catalog.
    func isAlreadyOn(_ server: HostServerKey) -> Bool {
        existing?.record(of: server) != nil
    }

    /// How many Servers finishing turns on.
    var checkedCount: Int {
        scan?.servers.filter { checked.contains($0.key) && !isAlreadyOn($0.key) }.count ?? 0
    }

    /// Connects and looks for Servers. The second step shows on its own when the
    /// transport asks about the key.
    func connect() async {
        guard let host = draft.makeHost(id: recordID) else { return }
        failure = nil
        trustedCandidate = nil
        // A key trusted on an earlier attempt belongs to the machine those
        // routes reached, which edited routes may no longer name.
        let routes = HostMachine.Connection(host).routes
        if let attemptedRoutes, attemptedRoutes != routes {
            await knownHosts.forgetHost(recordID)
            // What a Pairing Code said was said of the machine it named.
            runsHerdrTUI = false
            trustsPairingCode = false
        }
        attemptedRoutes = routes
        if let pairedFingerprint {
            let key = HostKeyTrust.hostKey(recordID)
            await knownHosts.setFingerprint(pairedFingerprint, host: key.host, port: key.port)
            self.pairedFingerprint = nil
            trustsPairingCode = true
        }
        // A Host that is in the catalog was trusted there: its key is not
        // asked about twice, and a key that changed since is still refused,
        // unless a Pairing Code just pinned the one the Host has now.
        if !trustsPairingCode, let existing {
            await knownHosts.copyTrust(from: existing.representative.id, to: recordID)
        }
        let found = await scanner.look(at: host, typedPassword: draft.passwordUpdate).map { vouchedFor($0) }
        didTrust = false
        if let found {
            scan = found
            checked = Set(found.servers.filter(\.startsChecked).map(\.key))
            replacesTrustedKey = await catalogTrustsAnotherKey()
        } else {
            scan = nil
            replacesTrustedKey = false
            if case .failed(let failure) = scanner.phase, !failure.isDeclinedTrust {
                self.failure = failure
            }
        }
    }

    /// What a look found, with the Herdr TUI a Pairing Code vouched for.
    private func vouchedFor(_ found: HostServerScan) -> HostServerScan {
        runsHerdrTUI ? found.assumingHerdrTUI() : found
    }

    /// Whether a record of the Host in the catalog trusts a key the look, which
    /// went by the Pairing Code's, did not meet.
    private func catalogTrustsAnotherKey() async -> Bool {
        guard trustsPairingCode, let existing else { return false }
        let pinned = await trustedKeys(of: recordID)
        for member in existing.members {
            let trusted = await trustedKeys(of: member.id)
            let holdsPinned = pinned.allSatisfy { key in trusted.contains { $0.digest == key.digest } }
            if !trusted.isEmpty, !holdsPinned { return true }
        }
        return false
    }

    private func trustedKeys(of record: Host.ID) async -> [HostKeyFingerprint] {
        let key = HostKeyTrust.hostKey(record)
        return await knownHosts.fingerprints(host: key.host, port: key.port)
    }

    /// The key the second step shows: the one being asked about, or the one
    /// just trusted while the look goes on.
    var candidate: HostKeyCandidate? { scanner.pendingFingerprint ?? trustedCandidate }

    func trust() {
        trustedCandidate = scanner.pendingFingerprint
        didTrust = true
        scanner.confirmFingerprint(trusted: true)
    }

    func declineTrust() {
        scanner.confirmFingerprint(trusted: false)
    }

    /// Back from the second step: the attempt ends and the form is as it was.
    func backToConnect() {
        scanner.cancel()
        didTrust = false
        scan = nil
    }

    /// Looks again from the last step, which stays up meanwhile. A Host that no
    /// longer answers goes back to the first step to say why.
    func scanAgain() async {
        guard !scanner.isLooking, let host = draft.makeHost(id: recordID) else { return }
        isScanningAgain = true
        let found = await scanner.look(at: host, typedPassword: draft.passwordUpdate).map { vouchedFor($0) }
        isScanningAgain = false
        if let found {
            let before = Set(scan?.servers.map(\.key) ?? [])
            scan = found
            // What is newly found starts as the rest did.
            checked.formUnion(
                found.servers.filter { $0.startsChecked && !before.contains($0.key) }.map(\.key))
        } else if case .failed(let failure) = scanner.phase {
            scan = nil
            replacesTrustedKey = false
            self.failure = failure.isDeclinedTrust ? nil : failure
        }
    }

    /// Saves the Host with the checked Servers on, or with none. A Host already
    /// in the catalog under the same connection takes them instead of a second
    /// entry. Returns a record of the Host, nil when nothing could be saved.
    func finish(switcher: HostServerSwitch, discoveries: HostServerDiscoveryStore) async -> Host.ID? {
        guard !isSaving, let host = draft.makeHost(id: recordID) else { return nil }
        isSaving = true
        defer { isSaving = false }
        let connection = HostMachine.Connection(host)
        let member: Host.ID
        if let existing {
            member = existing.representative.id
            // The ceremony enrolled this device there again, and the look just
            // met the key its code pinned.
            if trustsPairingCode, scan != nil {
                await switcher.pairAgain(hostOf: member, trusting: recordID)
            }
        } else {
            do {
                try catalog.add(host, password: draft.passwordUpdate)
            } catch {
                saveFailure = String(localized: "The Host could not be saved.")
                return nil
            }
            didSave = true
            member = recordID
        }
        guard let scan else { return member }
        discoveries.note(scan, on: connection, shown: true)
        for server in scan.servers where checked.contains(server.key) {
            do {
                try await switcher.turnOn(server.key, onHostOf: member, scan: scan)
            } catch {
                saveFailure = switcher.refusal(error, turningOn: server.key)
                break
            }
        }
        return member
    }

    func dismissSaveFailure() {
        saveFailure = nil
    }

    /// The wizard is going away. A key trusted for a Host that was never saved
    /// is forgotten with it.
    func close() async {
        scanner.cancel()
        if !didSave { await knownHosts.forgetHost(recordID) }
    }
}
