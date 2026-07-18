import Foundation
import Observation

/// Drives one Host's onboarding preflight (#14): resolve credentials,
/// connect (surfacing the TOFU first-connect prompt), ping, and render the
/// outcome as the checklist. One connect + ping is the whole probe —
/// preflight is the M0 error taxonomy, not new machinery (spec #20).
@MainActor
@Observable
final class HostOnboardingStore {
    enum Phase: Equatable {
        case idle
        case running
        case finished
    }

    private(set) var phase: Phase = .idle
    /// Set while the transport waits on the user's first-connect trust
    /// decision; the UI renders it as the fingerprint confirmation sheet.
    private(set) var pendingFingerprint: HostKeyCandidate?
    private(set) var report: PreflightReport?
    private(set) var serverInfo: ServerInfo?

    let host: Host

    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider
    /// The transport deliberately has no confirmation timeout (#2); the UI
    /// layer owns it (spec #20). An unanswered candidate is declined.
    @ObservationIgnored private let fingerprintTimeout: Duration
    @ObservationIgnored private var fingerprintDecision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var fingerprintTimeoutTask: Task<Void, Never>?

    init(
        host: Host,
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore(),
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        fingerprintTimeout: Duration = .seconds(60)
    ) {
        self.host = host
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
        self.fingerprintTimeout = fingerprintTimeout
    }

    /// Runs the preflight once: connect + ping, rendered into `report`.
    func runChecks() async {
        guard phase != .running else { return }
        phase = .running
        report = nil
        serverInfo = nil
        defer { phase = .finished }

        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch HostCredentialsError.passwordNotSet {
            report = .failure(
                check: .connection,
                hint: "No password is saved for this Host. Edit the Host and enter one.")
            return
        } catch {
            report = .failure(
                check: .connection,
                hint: "Could not load this Host's credentials. (\(error))")
            return
        }

        let policy = HostKeyPolicy(knownHosts: knownHosts) { [weak self] candidate in
            await self?.awaitFingerprintDecision(for: candidate) ?? false
        }
        let settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy)
        do {
            let transport = try await connector.connect(settings: settings)
            do {
                serverInfo = try await transport.ping()
                report = .allPassed
            } catch {
                report = failureReport(error)
            }
            // Preflight only probes; the Console owns long-lived connections.
            try? await transport.close()
        } catch {
            report = failureReport(error)
        }
    }

    /// The user's verdict on the pending fingerprint.
    func confirmFingerprint(trusted: Bool) {
        resolveFingerprint(trusted)
    }

    private func failureReport(_ error: any Error) -> PreflightReport {
        if let transportError = error as? TransportError {
            .failure(transportError, authMethod: host.authMethod)
        } else {
            .failure(
                check: .connection,
                hint: "The connection failed unexpectedly. (\(error))")
        }
    }

    private func awaitFingerprintDecision(for candidate: HostKeyCandidate) async -> Bool {
        // One connect per run means one candidate at a time; decline a
        // second defensively instead of leaking the first continuation.
        guard fingerprintDecision == nil else { return false }
        pendingFingerprint = candidate
        return await withCheckedContinuation { continuation in
            fingerprintDecision = continuation
            fingerprintTimeoutTask = Task { [fingerprintTimeout] in
                try? await Task.sleep(for: fingerprintTimeout)
                guard !Task.isCancelled else { return }
                self.resolveFingerprint(false)
            }
        }
    }

    private func resolveFingerprint(_ trusted: Bool) {
        guard let decision = fingerprintDecision else { return }
        fingerprintDecision = nil
        fingerprintTimeoutTask?.cancel()
        fingerprintTimeoutTask = nil
        pendingFingerprint = nil
        decision.resume(returning: trusted)
    }
}
