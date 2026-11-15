import Foundation
import Observation

/// One look at a Host for its Servers (ADR 0047): connect, have the user trust
/// a key seen for the first time, run the one detection exec, close. It dials
/// as one record of the Host, whose trust and password every record shares,
/// and starts nothing there.
@MainActor
@Observable
final class HostServerScanner {
    enum Phase: Equatable {
        case idle
        case looking
        case found(HostServerScan)
        case failed(Failure)
    }

    /// Why a look found nothing to report.
    struct Failure: Error, Equatable {
        /// What happened, in a few words.
        let summary: String
        /// What happened and what to do about it.
        let message: String
        /// An Overlay Network is waiting for an interactive sign-in.
        var overlayLoginURL: URL?
        /// The user declined the key, which is an answer and not a fault.
        var isDeclinedTrust = false
    }

    private(set) var phase: Phase = .idle
    /// Set while the transport waits on the user's first-connect decision.
    private(set) var pendingFingerprint: HostKeyCandidate?
    /// Set after a look stopped at a changed key, until the user replaces the
    /// pin or looks again.
    private(set) var pendingHostKeyReplacement: HostKeyReplacement?

    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider
    @ObservationIgnored private let overlays: OverlayNetworkRuntime
    /// The transport has no confirmation timeout of its own; an unanswered
    /// candidate is declined.
    @ObservationIgnored private let fingerprintTimeout: Duration
    @ObservationIgnored private var fingerprintDecision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var fingerprintTimeoutTask: Task<Void, Never>?
    /// Identifies the prompt `fingerprintDecision` answers.
    @ObservationIgnored private var fingerprintPrompt: UUID?
    @ObservationIgnored private var looking: Task<Result<HostServerScan, Failure>, Never>?
    /// Identifies the look whose prompts and outcome still count.
    @ObservationIgnored private var currentLook = UUID()

    init(
        dependencies: HostOnboardingDependencies = HostOnboardingDependencies(),
        overlays: OverlayNetworkRuntime = .shared,
        fingerprintTimeout: Duration = .seconds(60)
    ) {
        connector = dependencies.connector
        knownHosts = dependencies.knownHosts
        credentials = dependencies.credentials
        self.overlays = overlays
        self.fingerprintTimeout = fingerprintTimeout
    }

    var isLooking: Bool { phase == .looking }

    /// Looks once, replacing a look still under way. `typedPassword` is a
    /// password not stored yet, for a Host still being added. A look that may
    /// not ask (`asksToTrust` false) declines a key it has not seen, so nothing
    /// in the background ever puts up a prompt. Nil when it failed, was
    /// cancelled, or another look replaced it.
    @discardableResult
    func look(at host: Host, typedPassword: String? = nil, asksToTrust: Bool = true) async -> HostServerScan? {
        cancel()
        let look = UUID()
        currentLook = look
        phase = .looking
        pendingHostKeyReplacement = nil
        let task = Task {
            await self.perform(host: host, typedPassword: typedPassword, asksToTrust: asksToTrust, look: look)
        }
        looking = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard currentLook == look else { return nil }
        looking = nil
        guard !task.isCancelled else {
            resolveFingerprint(false)
            phase = .idle
            return nil
        }
        switch outcome {
        case .success(let scan):
            phase = .found(scan)
            return scan
        case .failure(let failure):
            phase = .failed(failure)
            return nil
        }
    }

    /// Stops a look without waiting for its timeout. A trust prompt still open
    /// is declined, never left dangling.
    func cancel() {
        currentLook = UUID()
        looking?.cancel()
        looking = nil
        resolveFingerprint(false)
        if phase == .looking { phase = .idle }
    }

    /// The user's verdict on the pending fingerprint.
    func confirmFingerprint(trusted: Bool) {
        resolveFingerprint(trusted)
    }

    /// Replaces the changed pin for every record of the Host, after the UI
    /// obtained an explicit confirmation. A Jump Host's pin is kept by the
    /// endpoint dialled, once for all.
    func trustPresentedHostKey(for records: [Host.ID]) async {
        guard let replacement = pendingHostKeyReplacement else { return }
        if let jumpHost = replacement.jumpHost {
            let key = HostKeyTrust.endpoint.storageKey(host: jumpHost.address, port: jumpHost.port)
            await knownHosts.setFingerprint(replacement.presented, host: key.host, port: key.port)
        } else {
            for record in records {
                let key = HostKeyTrust.hostKey(record)
                await knownHosts.setFingerprint(replacement.presented, host: key.host, port: key.port)
            }
        }
        pendingHostKeyReplacement = nil
    }

    private func perform(
        host: Host, typedPassword: String?, asksToTrust: Bool, look: UUID
    ) async -> Result<HostServerScan, Failure> {
        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host, typedPassword: typedPassword)
        } catch HostCredentialsError.passwordNotSet {
            return .failure(
                Failure(
                    summary: String(localized: "No password saved"),
                    message: String(localized: "No password is saved for this Host. Edit the Host and enter one.")))
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            return .failure(Failure(TransportError.deviceKeyCorrupt, host: host))
        } catch RSAKeyStoreError.storedKeyCorrupt {
            return .failure(Failure(TransportError.rsaKeyCorrupt, host: host))
        } catch {
            return .failure(
                Failure(
                    summary: String(localized: "Credentials unavailable"),
                    message: String(localized: "Could not load this Host's credentials. (\(String(describing: error)))")))
        }

        let policy = HostKeyPolicy(knownHosts: knownHosts) { [weak self] candidate in
            guard asksToTrust else { return false }
            return await self?.awaitFingerprintDecision(for: candidate, look: look) ?? false
        }
        let settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy, overlays: overlays)
        let connection: any ServerKindDetectionConnection
        do {
            connection = try await connector.connectForDetection(settings: settings)
        } catch {
            if currentLook == look, !Task.isCancelled {
                pendingHostKeyReplacement = HostKeyReplacement.offered(by: error, for: host)
            }
            return .failure(Failure(error, host: host))
        }
        let outcome: Result<HostServerScan, Failure>
        do {
            // The default session is the one a look can name: a core session the
            // user named is turned on by that name.
            outcome = .success(HostServerScan(try await ServerKindDetection.run(over: connection, session: "")))
        } catch {
            outcome = .failure(Failure(error, host: host))
        }
        try? await connection.close()
        return outcome
    }

    private func awaitFingerprintDecision(for candidate: HostKeyCandidate, look: UUID) async -> Bool {
        // A cancelled look's late handshake never asks the user.
        guard currentLook == look else { return false }
        // The transport asks about one key at a time, even while routes race;
        // decline a second instead of leaking the first continuation.
        guard fingerprintDecision == nil, !Task.isCancelled else { return false }
        pendingFingerprint = candidate
        let prompt = UUID()
        fingerprintPrompt = prompt
        // A route that loses the race is cancelled while its key may still be
        // on screen; its prompt goes away with it.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fingerprintDecision = continuation
                fingerprintTimeoutTask = Task { [fingerprintTimeout] in
                    try? await Task.sleep(for: fingerprintTimeout)
                    guard !Task.isCancelled else { return }
                    self.resolveFingerprint(false)
                }
            }
        } onCancel: {
            Task { @MainActor in
                // Only this prompt: a later one may already be showing.
                if self.fingerprintPrompt == prompt { self.resolveFingerprint(false) }
            }
        }
    }

    private func resolveFingerprint(_ trusted: Bool) {
        guard let decision = fingerprintDecision else { return }
        fingerprintDecision = nil
        fingerprintPrompt = nil
        fingerprintTimeoutTask?.cancel()
        fingerprintTimeoutTask = nil
        pendingFingerprint = nil
        decision.resume(returning: trusted)
    }
}

extension HostServerScanner.Failure {
    /// A failed connection or exec, in the words Host detail's checks use.
    init(_ error: any Error, host: Host) {
        guard let transportError = error as? TransportError else {
            self.init(
                summary: String(localized: "Connection failed"),
                message: String(localized: "The connection failed unexpectedly. (\(String(describing: error)))"))
            return
        }
        let hint =
            PreflightReport.failure(transportError, authMethod: host.authMethod).failureHint
            ?? transportError.presentation.message
        self.init(
            summary: transportError.presentation.summary, message: hint,
            overlayLoginURL: transportError.overlayLoginURL)
        isDeclinedTrust = transportError.isDeclinedHostKey
    }
}

extension TransportError {
    /// The user was shown a key and declined it: the Host's, a Jump Host's one
    /// hop earlier, or either on one of several Routes, whatever stopped the
    /// others.
    fileprivate var isDeclinedHostKey: Bool {
        switch self {
        case .hostKeyRejected: true
        case .jumpHostFailed(let error): error.isDeclinedHostKey
        case .noRouteReached(let failures): failures.contains { $0.error.isDeclinedHostKey }
        default: false
        }
    }
}

extension KnownHostsStore {
    /// Gives `record` the host keys trusted for `source`. Both are records of
    /// one Host, which presents one key whichever Server is asked (ADR 0047).
    func copyTrust(from source: Host.ID, to record: Host.ID) async {
        let from = HostKeyTrust.hostKey(source)
        let to = HostKeyTrust.hostKey(record)
        for fingerprint in await fingerprints(host: from.host, port: from.port) {
            await setFingerprint(fingerprint, host: to.host, port: to.port)
        }
    }
}
