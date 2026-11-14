import Foundation
import Observation

/// A verified mismatch awaiting the user's explicit decision to replace the
/// trusted pin. Merely observing a mismatch never mutates the known-hosts store.
struct HostKeyReplacement: Equatable, Sendable {
    /// A Jump Host, whose trust is kept by the endpoint dialled (ADR 0022).
    struct JumpHost: Equatable, Sendable {
        let address: String
        let port: Int

        /// The Jump Host `route` dials, as `SSHTransportSettings(host:)`
        /// dials it; nil for a route without one.
        init?(_ route: HostRoute) {
            guard route.usesJumpHost else { return nil }
            address = route.jumpAddress.trimmingCharacters(in: .whitespaces)
            port = route.jumpPort
        }

        /// `address`, with the port when it is not 22.
        var endpointDescription: String {
            port == 22 ? address : "\(address):\(port)"
        }
    }

    let known: HostKeyFingerprint
    let presented: HostKeyFingerprint
    /// Whose key changed: this Jump Host's, or the Host's own when nil.
    var jumpHost: JumpHost? = nil
}

/// What Host onboarding connects and authenticates with. Production uses SSH
/// and the Keychain; screenshot mode swaps in process-local stand-ins.
struct HostOnboardingDependencies: Sendable {
    var connector: any TransportConnector = SSHTransportConnector()
    var knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared
    var credentials = HostCredentialsProvider()
    /// An action on a Host's Helper has run, so what follows it should look again.
    var hostHelperDidChange: @MainActor @Sendable () -> Void = {}
    /// What this device applied, for removing the Helper to undo what goes with it.
    var harnessEdits: HarnessConfigEditStore?
    /// Add Host's detection found a native Windows machine behind this Host, which
    /// its first connection may never reach to say.
    var noteWindowsCore: @MainActor @Sendable (Host.ID) -> Void = { _ in }
    /// The kernel a herdr-core Host's locator last found, nil before any has.
    var coreKernel: @MainActor @Sendable (Host.ID) -> String? = { _ in nil }
    /// A tmux Host's checks resolved its paths again, for the catalog to keep.
    var noteTmuxPaths: @MainActor @Sendable (Host.ID, TmuxPaths) -> Void = { _, _ in }
}

/// Drives one Host's onboarding preflight (#14): resolve credentials,
/// connect (surfacing the TOFU first-connect prompt), discover sessions,
/// ping the selected session, and render the outcome as the checklist. A
/// Host with a herdr endpoint (ADR 0023) skips discovery, because its socket
/// already fixes the session, and must instead prove its launcher answers. A
/// Host added unconfirmed first detects which servers it runs and has the user
/// confirm one kind, then runs that kind's checks (ADR 0031). A tmux Host's
/// checks ask its server and start none (ADR 0044).
@MainActor
@Observable
final class HostOnboardingStore {
    enum Phase: Equatable {
        case idle
        case running
        case finished
    }

    /// The plugin notice's action, once the user runs it.
    enum PluginActionState: Equatable {
        case idle
        case running
        case failed(HeelerPluginActionFailure)
    }

    private(set) var phase: Phase = .idle
    /// Set while the transport waits on the user's first-connect trust
    /// decision; the UI renders it as the fingerprint confirmation sheet.
    private(set) var pendingFingerprint: HostKeyCandidate?
    /// Set only after a hard-failed mismatch, the Host's or a Jump Host's,
    /// for the UI's explicit re-trust flow. The old pin remains
    /// authoritative until the user confirms.
    private(set) var pendingHostKeyReplacement: HostKeyReplacement?
    private(set) var report: PreflightReport?
    private(set) var serverInfo: ServerInfo?
    private(set) var availableSessions: [HerdrSession] = []
    private(set) var sessionDiscoveryError: String?
    /// The Heeler plugin as the preflight connection found it. Read after a
    /// passing ping, so an unreachable Host reports `.unavailable`.
    private(set) var pluginStatus: HeelerPluginStatus = .checking
    private(set) var pluginAction: PluginActionState = .idle
    /// Set when the last run stopped at an Overlay Network that needs an
    /// interactive sign-in; the UI offers to open it.
    private(set) var overlayLoginURL: URL?
    /// What an unconfirmed Host's one detection exec found.
    private(set) var detection: ServerKindDetection?
    /// Why a reached Host could not be read, which leaves its kind to the user.
    private(set) var detectionFailure: String?
    /// Why the last confirmation was refused, for the user to read.
    private(set) var confirmationRefusal: String?
    /// The socket a tmux confirmation names: one detection offered, or the typed
    /// name when no server answers.
    private(set) var tmuxSocket = TmuxSocketName.defaultName
    /// What a tmux Host's server answered on the last checks.
    private(set) var tmuxStatus: TmuxServerStatus?
    /// What the locator found on a core Host the last checks read as not running.
    private var notRunningCore: HerdrCoreLocator.Location?
    /// Set from the user's request until they answer it.
    private(set) var coreStartConfirmation: CoreStartConfirmation?
    private(set) var coreStart: CoreStartState = .idle

    /// A herdr-core Host's Host Helper, read with its checks.
    private(set) var hostHelper: HostHelperStore?

    private(set) var host: Host

    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider
    @ObservationIgnored private let overlays: OverlayNetworkRuntime
    /// The transport deliberately has no confirmation timeout (#2); the UI
    /// layer owns it (spec #20). An unanswered candidate is declined.
    @ObservationIgnored private let fingerprintTimeout: Duration
    @ObservationIgnored private let coreHolderRestart: HerdrCoreHolderRestartPolicy
    @ObservationIgnored private let sleep: HerdrCoreHostSession.Sleep
    @ObservationIgnored private var fingerprintDecision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var fingerprintTimeoutTask: Task<Void, Never>?
    /// Identifies the prompt `fingerprintDecision` answers.
    @ObservationIgnored private var fingerprintPrompt: UUID?
    @ObservationIgnored private var checks: Task<Void, Never>?
    /// Identifies the run whose trust prompts may still be shown.
    @ObservationIgnored private var currentRun = UUID()
    @ObservationIgnored private let hostHelperDidChange: @MainActor () -> Void
    @ObservationIgnored private let noteWindowsCore: @MainActor (Host.ID) -> Void
    @ObservationIgnored private let noteTmuxPaths: @MainActor (Host.ID, TmuxPaths) -> Void
    @ObservationIgnored private let hostHelperHealthGap: @Sendable () async throws -> Void
    @ObservationIgnored private let harnessEdits: HarnessConfigEditStore?
    /// A Mac's second health read, which outlives the run that began it and owns
    /// that run's connection until it ends.
    @ObservationIgnored private(set) var hostHelperConfirmation: Task<Void, Never>?

    init(
        host: Host,
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        overlays: OverlayNetworkRuntime = .shared,
        fingerprintTimeout: Duration = .seconds(60),
        coreHolderRestart: HerdrCoreHolderRestartPolicy = .default,
        sleep: @escaping HerdrCoreHostSession.Sleep = { try await Task.sleep(for: $0) },
        hostHelperDidChange: @escaping @MainActor () -> Void = {},
        hostHelperHealthGap: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: HostHelperLaunchAgent.healthGap)
        },
        harnessEdits: HarnessConfigEditStore? = nil,
        noteWindowsCore: @escaping @MainActor (Host.ID) -> Void = { _ in },
        noteTmuxPaths: @escaping @MainActor (Host.ID, TmuxPaths) -> Void = { _, _ in }
    ) {
        self.noteWindowsCore = noteWindowsCore
        self.noteTmuxPaths = noteTmuxPaths
        tmuxSocket = TmuxSocketName.normalized(host.sessionName)
        self.hostHelperHealthGap = hostHelperHealthGap
        self.harnessEdits = harnessEdits
        self.coreHolderRestart = coreHolderRestart
        self.sleep = sleep
        self.host = host
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
        self.overlays = overlays
        self.fingerprintTimeout = fingerprintTimeout
        self.hostHelperDidChange = hostHelperDidChange
    }

    /// Runs the preflight once: connect + ping, rendered into `report`.
    /// `cancelChecks()` (or cancelling the caller) ends it at once.
    /// `coreReportedRunning` is true only straight after a Start, when the core
    /// has just said it runs, which a refused channel then cannot contradict.
    func runChecks(coreReportedRunning: Bool = false) async {
        guard phase != .running, pluginAction != .running, coreStart != .running else { return }
        cancelHostHelperConfirmation()
        phase = .running
        pluginAction = .idle
        report = nil
        serverInfo = nil
        availableSessions = []
        sessionDiscoveryError = nil
        pluginStatus = .checking
        pendingHostKeyReplacement = nil
        overlayLoginURL = nil
        detection = nil
        detectionFailure = nil
        confirmationRefusal = nil
        tmuxStatus = nil
        tmuxSocket = TmuxSocketName.normalized(host.sessionName)
        notRunningCore = nil
        coreStartConfirmation = nil
        coreStart = .idle
        if host.serverKind == .herdrCore || host.serverKind == .tmux {
            let hostHelper = hostHelper ?? makeHostHelper()
            hostHelper.checkStarted()
            self.hostHelper = hostHelper
        }
        let run = UUID()
        currentRun = run
        let task = Task { await self.performChecks(run: run, coreReportedRunning: coreReportedRunning) }
        checks = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard checks == task else { return }
        checks = nil
        if task.isCancelled {
            markCancelled()
        } else {
            settleUnreadStatuses()
            phase = .finished
        }
    }

    /// What a finished run never got to read is unknown, not still being checked.
    private func settleUnreadStatuses() {
        if pluginStatus == .checking { pluginStatus = .unavailable }
        guard hostHelperConfirmation == nil else { return }
        hostHelper?.checkEnded(
            unreadBecause: report?.failureHint ?? String(localized: "The checks ended before reading this Host."))
    }

    private func cancelHostHelperConfirmation() {
        hostHelperConfirmation?.cancel()
        hostHelperConfirmation = nil
    }

    /// Stops a preflight still connecting — through an Overlay Network
    /// that is slow to come up, say — without waiting for its timeout. The
    /// checklist then says the check was cancelled.
    func cancelChecks() {
        guard phase == .running, let checks else { return }
        checks.cancel()
        self.checks = nil
        markCancelled()
    }

    private func markCancelled() {
        currentRun = UUID()
        // A trust prompt still open is declined, never left dangling.
        resolveFingerprint(false)
        report = .failure(TransportError.cancelled, authMethod: host.authMethod)
        overlayLoginURL = nil
        cancelHostHelperConfirmation()
        settleUnreadStatuses()
        phase = .finished
    }

    /// The checks themselves. Every write after an await first checks for
    /// cancellation: a cancelled run may still finish in the background.
    private func performChecks(run: UUID, coreReportedRunning: Bool) async {
        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch HostCredentialsError.passwordNotSet {
            report = .failure(
                check: .connection,
                hint: String(localized: "No password is saved for this Host. Edit the Host and enter one."))
            return
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            report = .failure(.deviceKeyCorrupt, authMethod: host.authMethod)
            return
        } catch RSAKeyStoreError.storedKeyCorrupt {
            report = .failure(.rsaKeyCorrupt, authMethod: host.authMethod)
            return
        } catch {
            report = .failure(
                check: .connection,
                hint: String(localized: "Could not load this Host's credentials. (\(String(describing: error)))"))
            return
        }

        let policy = HostKeyPolicy(knownHosts: knownHosts) { [weak self] candidate in
            await self?.awaitFingerprintDecision(for: candidate, run: run) ?? false
        }
        let settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy, overlays: overlays)
        switch host.serverKind {
        case .unconfirmed:
            await performDetection(settings: settings)
            return
        case .herdrCore:
            await performCoreChecks(settings: settings, coreReportedRunning: coreReportedRunning)
            return
        case .tmux:
            await performTmuxChecks(settings: settings)
            return
        case .herdrTUI:
            break
        }
        do {
            let transport = try await connector.connect(settings: settings)
            guard !Task.isCancelled else {
                try? await transport.close()
                return
            }
            let launcherFailure: PreflightReport?
            if let endpoint = host.herdrEndpoint {
                launcherFailure = await launcherProbeFailure(endpoint, over: transport)
            } else {
                launcherFailure = nil
                do {
                    let sessions = try await transport.listSessions()
                    if !Task.isCancelled { availableSessions = sessions }
                } catch {
                    if !Task.isCancelled {
                        sessionDiscoveryError = String(localized: "Could not discover herdr sessions. You can still enter a session name manually.")
                    }
                }
            }
            guard !Task.isCancelled else {
                try? await transport.close()
                return
            }
            if let launcherFailure {
                report = launcherFailure
            } else {
                do {
                    let info = try await transport.ping()
                    if !Task.isCancelled {
                        serverInfo = info
                        report = .allPassed
                        // After the report, so the checklist renders first. The
                        // run still waits for this read (bounded by the request
                        // timeout), and its failure never fails the preflight.
                        let plugin = await HeelerPluginStatus.read(over: transport)
                        if !Task.isCancelled { pluginStatus = plugin }
                    }
                } catch {
                    if !Task.isCancelled {
                        captureHostKeyReplacement(error)
                        report = failureReport(error)
                    }
                }
            }
            // Preflight only probes; the Console owns long-lived connections.
            try? await transport.close()
        } catch {
            guard !Task.isCancelled else { return }
            captureHostKeyReplacement(error)
            report = failureReport(error)
        }
    }

    /// A core Host's preflight: the locator, `hello` with its feature gate, and
    /// close. It starts nothing. The plugin does not run here, whatever the core
    /// answers, and no Herdr TUI session is looked for.
    private func performCoreChecks(settings: SSHTransportSettings, coreReportedRunning: Bool) async {
        pluginStatus = .unsupportedServerKind
        do {
            let transport = try await connector.connectCore(settings: settings)
            guard !Task.isCancelled else {
                try? await transport.close()
                return
            }
            // The Helper does not need a core, so it reads whether one runs or not.
            // Beside the core's checks, and a Mac's second health read, over ten
            // seconds away, goes on after them: they should not wait for it.
            let helper = hostHelper
            async let helperRead = helper?.beginRefresh(over: transport)
            do {
                // Straight after a Start nothing is on its way back: the core
                // said it runs, so a refused channel is SSH's refusal.
                let info =
                    coreReportedRunning
                    ? try await transport.hello()
                    : try await transport.helloAcrossHolderRestart(
                        policy: coreHolderRestart, sleep: sleep, isWanted: { !Task.isCancelled })
                if !Task.isCancelled {
                    serverInfo = ServerInfo(version: info.version, protocolVersion: info.generation)
                    report = .allPassed
                }
            } catch let TransportError.herdrCoreNotRunning(socketPath, _) where coreReportedRunning {
                if !Task.isCancelled {
                    report = failureReport(TransportError.herdrCoreForwardingRefused(socketPath: socketPath))
                }
            } catch {
                let location = await transport.lastLocation()
                if !Task.isCancelled {
                    if case TransportError.herdrCoreNotRunning = error { notRunningCore = location }
                    report = failureReport(error)
                }
            }
            guard let confirmation = await helperRead, !Task.isCancelled else {
                try? await transport.close()
                return
            }
            hostHelperConfirmation = Task {
                await confirmation()
                try? await transport.close()
            }
        } catch {
            guard !Task.isCancelled else { return }
            captureHostKeyReplacement(error)
            report = failureReport(error)
        }
    }

    /// A tmux Host's preflight: one ask of its server, with the stored paths
    /// while they answer and through the login shell once they do not, its
    /// Host Helper read over the same connection, and close. It starts nothing.
    /// Paths resolved again go to the catalog before the Helper plan is built.
    private func performTmuxChecks(settings: SSHTransportSettings) async {
        pluginStatus = .unsupportedServerKind
        do {
            let transport = try await connector.connectTmux(settings: settings)
            guard !Task.isCancelled else {
                try? await transport.close()
                return
            }
            let outcome: Result<TmuxServerStatus, any Error>
            do {
                outcome = .success(try await transport.status())
            } catch {
                outcome = .failure(error)
            }
            let resolved = await transport.resolvedPaths()
            guard !Task.isCancelled else {
                try? await transport.close()
                return
            }
            if let resolved, resolved != host.tmuxPaths {
                host.tmuxPaths = resolved
                noteTmuxPaths(host.id, resolved)
            }
            switch outcome {
            case .success(let status):
                tmuxStatus = status
                report = .allPassed
            case .failure(let error):
                report = failureReport(error)
            }
            guard let confirmation = await hostHelper?.beginRefresh(over: transport), !Task.isCancelled else {
                try? await transport.close()
                return
            }
            hostHelperConfirmation = Task {
                await confirmation()
                try? await transport.close()
            }
        } catch {
            guard !Task.isCancelled else { return }
            captureHostKeyReplacement(error)
            report = failureReport(error)
        }
    }

    /// The Helper's actions dial for themselves, after the preflight settled the
    /// Host key: a key that still needs trusting is declined.
    private func makeHostHelper() -> HostHelperStore {
        let initialHost = host
        let connector = connector
        let knownHosts = knownHosts
        let credentials = credentials
        let overlays = overlays
        let store = HostHelperStore(
            connect: { [weak self] in
                let host = await MainActor.run { self?.host ?? initialHost }
                let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
                let settings = SSHTransportSettings(
                    host: host, credentials: try credentials.credentials(for: host),
                    hostKeyPolicy: policy, overlays: overlays)
                if host.serverKind == .tmux {
                    let transport = try await connector.connectTmux(settings: settings)
                    if host.tmuxPaths == nil {
                        _ = try? await transport.status()
                        if let resolved = await transport.resolvedPaths() {
                            await MainActor.run { [weak self] in
                                guard let self, self.host.tmuxPaths != resolved else { return }
                                self.host.tmuxPaths = resolved
                                self.noteTmuxPaths(self.host.id, resolved)
                            }
                        }
                    }
                    return transport
                }
                return try await connector.connectCore(settings: settings)
            },
            tmuxPaths: { [weak self] in self?.host.tmuxPaths ?? initialHost.tmuxPaths },
            healthGap: hostHelperHealthGap,
            undoEdits: { [harnessEdits, hostID = initialHost.id] services in
                try await harnessEdits?.undoEditsGoingWithTheHelper(on: hostID, over: services)
            })
        store.onChanged = hostHelperDidChange
        return store
    }

    /// One exec over a connection of its own, which starts no server. A Host
    /// out of reach reads as the preflight's connection failure.
    private func performDetection(settings: SSHTransportSettings) async {
        do {
            let connection = try await connector.connectForDetection(settings: settings)
            guard !Task.isCancelled else {
                try? await connection.close()
                return
            }
            do {
                let found = try await ServerKindDetection.run(over: connection, session: host.sessionName)
                if !Task.isCancelled {
                    detection = found
                    tmuxSocket = found.preselectedTmuxSocket(typed: host.sessionName)
                }
            } catch {
                if !Task.isCancelled {
                    detectionFailure = (error as? TransportError)?.presentation.message ?? "\(error)"
                }
            }
            try? await connection.close()
        } catch {
            guard !Task.isCancelled else { return }
            captureHostKeyReplacement(error)
            report = failureReport(error)
        }
    }

    /// The kinds the user may confirm: none until the Host has been reached.
    var offeredKinds: [ServerKind] {
        guard host.serverKind == .unconfirmed else { return [] }
        if let detection { return detection.offeredKinds }
        return detectionFailure == nil ? [] : ServerKindDetection.offeredWithoutFindings
    }

    /// A tmux Host's checks found its tmux and no server on its socket.
    var isWaitingForTmuxServer: Bool {
        guard host.serverKind == .tmux, case .failed? = report?[.serverRunning] else { return false }
        return true
    }

    /// The sockets a tmux server answers on, for the confirmation to choose from.
    var tmuxSocketChoices: [String] {
        host.serverKind == .unconfirmed ? detection?.tmuxSockets ?? [] : []
    }

    /// Chooses the socket a tmux confirmation names, among those offered.
    func selectTmuxSocket(_ name: String) {
        guard tmuxSocketChoices.contains(name) else { return }
        tmuxSocket = name
    }

    /// What the confirmation adds to the findings it lists, if anything.
    var confirmationNote: String? {
        if let detectionFailure {
            return String(localized: "Heeler could not read what this Host runs, so the choice is yours. \(detectionFailure)")
        }
        guard let detection else { return nil }
        if case .sessionRefused(let reason) = detection.herdrCore {
            return reason
        }
        switch detection.foundKinds.count {
        case 0:
            return detection.supportedKinds.count > 2
                ? String(localized: "None of them was found. Choose the one you will use, and its checks say how to set it up.")
                : String(localized: "Neither was found. Choose the one you will use, and its checks say how to set it up.")
        case 1:
            return nil
        case 2:
            return String(localized: "This machine runs both. A Host is one kind: confirm one here, then add the machine again for the other.")
        default:
            return String(localized: "This machine runs more than one. A Host is one kind: confirm one here, then add the machine again for each of the others.")
        }
    }

    /// Confirms the Host's kind, once, then runs that kind's checks. A name refused
    /// for that kind, by its server or by what this Host's platform can carry, leaves
    /// the Host as it was and says why.
    func confirmServerKind(_ kind: ServerKind, in catalog: HostStore) async {
        guard phase != .running, offeredKinds.contains(kind) else { return }
        if kind == .herdrCore, case .sessionRefused(let reason) = detection?.herdrCore {
            confirmationRefusal = reason
            return
        }
        if kind == .herdrCore, case .socketPathTooLong(_, let path, let limit) = detection?.herdrCore {
            confirmationRefusal =
                TransportError.herdrCoreSocketPathTooLong(path: path, limit: limit).presentation.message
            return
        }
        if kind == .herdrCore, detection?.isNativeWindows == true { noteWindowsCore(host.id) }
        do {
            // A tmux Host takes the socket chosen here, and the paths this
            // detection's login shell resolved for it (ADR 0044).
            host =
                kind == .tmux
                ? try catalog.confirmServerKind(
                    kind, for: host.id, sessionName: tmuxSocket,
                    tmuxPaths: detection?.tmuxPaths(socketName: tmuxSocket))
                : try catalog.confirmServerKind(kind, for: host.id)
        } catch HostStoreError.sessionNameRefused(let reason) {
            confirmationRefusal = reason
            return
        } catch HostStoreError.catalogUnreadable where kind == .tmux && catalog.tmuxCatalogLoadError != nil {
            confirmationRefusal =
                String(localized: "The saved tmux Hosts could not be read, so no tmux Host can be added.")
            return
        } catch HostStoreError.catalogUnreadable where catalog.coreCatalogLoadError != nil {
            confirmationRefusal =
                String(localized: "The saved herdr-core Hosts could not be read, so no herdr-core Host can be added.")
            return
        } catch {
            confirmationRefusal = String(
                localized: "The Server Kind could not be saved. (\(String(describing: error)))")
            return
        }
        await runChecks()
    }

    func dismissConfirmationRefusal() {
        confirmationRefusal = nil
    }

    /// What this Host offers once its checks read not running: Start on Linux,
    /// instructions anywhere else, naming the probed path and the core session.
    var coreStartOffer: CoreStartOffer? {
        guard phase == .finished, let notRunningCore, let path = notRunningCore.executablePath else {
            return nil
        }
        if notRunningCore.isNativeWindows {
            return .windowsInstructions(
                command: HerdrCoreStart.windowsManualCommand(executablePath: path, session: host.sessionName))
        }
        return notRunningCore.appMayStartCore
            ? .start
            : .instructions(
                command: HerdrCoreStart.manualCommand(executablePath: path, session: host.sessionName))
    }

    /// Asks the user. Nothing runs until `confirmCoreStart`.
    func requestCoreStart() {
        guard coreStartOffer == .start, coreStart != .running else { return }
        coreStartConfirmation = CoreStartConfirmation(
            session: HerdrCoreSessionName.normalized(host.sessionName))
    }

    func cancelCoreStart() {
        coreStartConfirmation = nil
    }

    /// The one action that starts a core (ADR 0031), after which the checks run
    /// again. A core that reported itself running and still refuses its channel
    /// leaves only the SSH server to blame.
    func confirmCoreStart() async {
        guard let confirmation = coreStartConfirmation else { return }
        coreStartConfirmation = nil
        guard phase != .running, coreStart != .running, pluginAction != .running else { return }
        coreStart = .running
        let result = await performCoreStart()
        switch result {
        case .failed(let message):
            coreStart = .failed(message: message)
        case .started, .alreadyRunning:
            coreStart = .idle
            await runChecks(coreReportedRunning: true)
            coreStart =
                result == .started
                ? .started(session: confirmation.session)
                : .alreadyRunning(session: confirmation.session)
        }
    }

    private enum CoreStartResult: Equatable {
        case started
        case alreadyRunning
        case failed(message: String)
    }

    /// The start over a connection of its own, like a plugin action's. The
    /// preflight already settled the Host key, so a key that still needs
    /// trusting is declined rather than asked about.
    private func performCoreStart() async -> CoreStartResult {
        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch {
            return .failed(
                message: String(
                    localized: "herdr-core did not start: Could not load this Host's credentials. (\(String(describing: error)))"))
        }
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
        let settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy, overlays: overlays)
        let transport: any HerdrCoreTransport
        do {
            transport = try await connector.connectCore(settings: settings)
        } catch {
            return .failed(message: String(localized: "herdr-core did not start: \(Self.reason(error))"))
        }
        let outcome: Result<HerdrCoreStart.Outcome, any Error>
        do {
            outcome = .success(try await transport.startCore())
        } catch {
            outcome = .failure(error)
        }
        try? await transport.close()
        switch outcome {
        case .success(.started):
            return .started
        case .success(.alreadyRunning):
            return .alreadyRunning
        case .success(.failed(let detail?)):
            return .failed(message: String(localized: "herdr-core did not start: \(detail)."))
        case .success(.failed(nil)):
            return .failed(message: String(localized: "herdr-core did not start."))
        case .failure(TransportError.timedOut):
            return .failed(
                message: String(localized: "The start did not finish in time, and a startup file in your shell may be waiting for input. Run the checks again to see whether the core came up."))
        case .failure(let error):
            return .failed(message: String(localized: "herdr-core did not start: \(Self.reason(error))"))
        }
    }

    private static func reason(_ error: any Error) -> String {
        (error as? TransportError)?.presentation.message ?? "\(error)"
    }

    /// The Host's kind, with the version a core's `hello` reported, which is
    /// advisory: a core other than the one this build was tested with still
    /// connects if `hello` passes.
    var serverKindSummary: String {
        if host.serverKind == .tmux, let tmuxStatus {
            return "\(host.serverKind.displayName) \(tmuxStatus.version)"
        }
        guard host.serverKind == .herdrCore, let serverInfo else { return host.serverKind.displayName }
        return "\(host.serverKind.displayName) \(serverInfo.version)"
    }

    var pluginPresentation: HeelerPluginPresentation {
        HeelerPluginPresentation(
            pluginStatus, session: host.sessionName, endpoint: host.herdrEndpoint)
    }

    /// Runs the plugin notice's action on the Host, then rereads the plugin,
    /// so the notice goes away once there is nothing left to do. Steps stop
    /// at the first failure, which herdr leaves the plugin as it was after.
    func runPluginAction(_ action: HeelerPluginPresentation.Notice.Action) async {
        guard phase != .running, pluginAction != .running else { return }
        pluginAction = .running
        let failure = await performPluginAction(action)
        pluginAction = failure.map(PluginActionState.failed) ?? .idle
    }

    /// The action over a connection of its own, like the preflight's: the
    /// Console's redials after a timeout and would run a step twice.
    private func performPluginAction(
        _ action: HeelerPluginPresentation.Notice.Action
    ) async -> HeelerPluginActionFailure? {
        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch {
            return HeelerPluginActionFailure(
                message: String(localized: "Could not load this Host's credentials. (\(String(describing: error)))"))
        }
        // The preflight already settled the Host key, so a key that still
        // needs trusting is declined rather than asked about mid-change.
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
        let settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy, overlays: overlays)
        let transport: any Transport
        do {
            transport = try await connector.connect(settings: settings)
        } catch {
            return HeelerPluginActionFailure(
                message: String(localized: "Heeler could not connect to the Host, so nothing changed."),
                detail: (error as? TransportError)?.presentation.message ?? "\(error)")
        }
        var steps = action.steps
        var skippedInstall: HeelerPluginActionFailure?
        if steps.contains(.install) {
            switch await installClearance(over: transport) {
            case .clear:
                break
            case .nothingNewer(let reason):
                // The action's other steps still apply.
                steps.removeAll { $0 == .install }
                skippedInstall = reason
            case .refused(let reason):
                try? await transport.close()
                return reason
            }
            if steps.isEmpty {
                try? await transport.close()
                return skippedInstall
            }
        }
        var stepError: (any Error)?
        for step in steps {
            do {
                try await transport.runHeelerPluginStep(step)
            } catch {
                stepError = error
                break
            }
        }
        // herdr's registry is the answer either way: a step that timed out
        // may still have finished, and two devices may update at once.
        let status = await HeelerPluginStatus.read(over: transport)
        try? await transport.close()
        switch status {
        case .installed, .notInstalled:
            pluginStatus = status
        case .checking, .unsupportedPlatform, .unsupportedServerKind, .unavailable:
            // An unreadable plugin keeps the last status in place. A step
            // whose connection dropped may have finished all the same.
            guard let stepError else {
                return HeelerPluginActionFailure(
                    message: String(localized: "The change finished, but the plugin could not be read back. Run the checks again."))
            }
            if let error = stepError as? TransportError, error != .timedOut {
                return HeelerPluginActionFailure(
                    message: String(localized: "The connection ended during the change, which may still finish on the Host. Run the checks again."),
                    detail: error.presentation.message)
            }
            return HeelerPluginActionFailure(stepError)
        }
        guard pluginPresentation.notice != nil else { return nil }
        if let stepError { return HeelerPluginActionFailure(stepError) }
        if let skippedInstall { return skippedInstall }
        let bundled = HeelerPluginCompatibility.bundled
        if let version = pluginStatus.confirmedVersion, version < bundled {
            return HeelerPluginActionFailure(
                message: String(localized: "herdr installed plugin \(String(describing: version)), the newest published, but this app expects \(String(describing: bundled))."))
        }
        return HeelerPluginActionFailure(
            message: String(localized: "The change finished, but the plugin still needs the attention described above."))
    }

    /// Whether an action's install may run. herdr installs whatever the
    /// plugin branch holds, and an app built ahead of the branch, or a Host
    /// installed from elsewhere, can have a newer plugin than that. The
    /// branch only moves forward (ADR 0026), so the version read here is the
    /// least herdr installs. The Host's plugin is reread rather than taken
    /// from the checks, since another device may have changed it; a refusal
    /// leaves the status alone, so the sheet keeps the action it explains.
    private enum InstallClearance {
        case clear
        /// The Host's plugin is newer than the branch.
        case nothingNewer(HeelerPluginActionFailure)
        case refused(HeelerPluginActionFailure)
    }

    private func installClearance(over transport: any Transport) async -> InstallClearance {
        let installed: PluginVersion
        switch await HeelerPluginStatus.read(over: transport) {
        case .notInstalled:
            return .clear
        case .installed(let installation):
            guard !installation.isLegacyID, installation.isReplaceableByInstall,
                let version = installation.parsedVersion
            else {
                return .refused(HeelerPluginActionFailure(
                    message: String(localized: "The plugin on the Host changed since the checks, so nothing changed. Run the checks again.")))
            }
            installed = version
        case .checking, .unsupportedPlatform, .unsupportedServerKind, .unavailable:
            return .refused(HeelerPluginActionFailure(
                message: String(localized: "Heeler could not read the Host's plugin before changing it, so nothing changed. Run the checks again.")))
        }
        let published: PluginVersion
        do {
            published = try await transport.readPluginBranchVersion()
        } catch {
            let detail =
                switch error {
                case let error as PluginBranchVersionError: error.output.isEmpty ? nil : error.output
                case let error as TransportError: error.presentation.message
                default: "\(error)"
                }
            return .refused(HeelerPluginActionFailure(
                message: String(localized: "Heeler could not check which plugin version the Host would install, so nothing changed. Check that the Host can reach github.com."),
                detail: detail))
        }
        guard published >= installed else {
            return .nothingNewer(HeelerPluginActionFailure(
                message: String(localized: "The Host has plugin \(String(describing: installed)), newer than the published \(String(describing: published)), so Heeler did not update it.")))
        }
        return .clear
    }

    /// The user's verdict on the pending fingerprint.
    func confirmFingerprint(trusted: Bool) {
        resolveFingerprint(trusted)
    }

    /// Persists a discovered session through the Host catalog. The Host
    /// detail then restarts onboarding for the updated Host, which
    /// immediately checks the selected socket.
    func selectSession(_ session: HerdrSession, in catalog: HostStore) throws {
        var updated = host
        updated.sessionName = session.isDefault ? "" : session.name
        try catalog.update(updated)
    }

    /// Replaces a mismatched pin only after the UI has obtained an explicit
    /// confirmation, then immediately proves the new pin by rerunning preflight.
    func trustPresentedHostKey() async {
        guard phase != .running, let replacement = pendingHostKeyReplacement else { return }
        let key =
            if let jumpHost = replacement.jumpHost {
                HostKeyTrust.endpoint.storageKey(host: jumpHost.address, port: jumpHost.port)
            } else {
                HostKeyTrust.hostKey(host.id)
            }
        await knownHosts.setFingerprint(replacement.presented, host: key.host, port: key.port)
        pendingHostKeyReplacement = nil
        await runChecks()
    }

    private func captureHostKeyReplacement(_ error: any Error) {
        switch error {
        case let TransportError.hostKeyMismatch(known, presented):
            pendingHostKeyReplacement = HostKeyReplacement(known: known, presented: presented)
        case let TransportError.jumpHostFailed(.hostKeyMismatch(known, presented)):
            // A single route fails with its own error, unwrapped.
            guard let jumpHost = host.routes.first.flatMap(HostKeyReplacement.JumpHost.init)
            else { return }
            pendingHostKeyReplacement = HostKeyReplacement(
                known: known, presented: presented, jumpHost: jumpHost)
        case TransportError.noRouteReached(let failures):
            // Every route reaches the same Host, so a changed key is offered
            // only when the routes that saw one agree on it. A LAN address may
            // be another machine elsewhere, so when any other route saw a
            // changed key, only those routes are asked.
            let mismatches = failures.compactMap {
                failure -> (mayNameAnotherMachine: Bool, replacement: HostKeyReplacement)? in
                guard case let .hostKeyMismatch(known, presented) = failure.error else {
                    return nil
                }
                return (
                    failure.mayNameAnotherMachine,
                    HostKeyReplacement(known: known, presented: presented))
            }
            let sameMachine = mismatches.filter { !$0.mayNameAnotherMachine }
            let candidates = (sameMachine.isEmpty ? mismatches : sameMachine).map(\.replacement)
            // A Jump Host's key belongs to another machine: it is offered
            // per Jump Host, and only when the Host's own key is not.
            let jumpHostCandidates = failures.compactMap { failure -> HostKeyReplacement? in
                guard case let .jumpHostFailed(.hostKeyMismatch(known, presented)) = failure.error,
                    let route = host.routes.first(where: { $0.id == failure.routeID }),
                    let jumpHost = HostKeyReplacement.JumpHost(route)
                else { return nil }
                return HostKeyReplacement(known: known, presented: presented, jumpHost: jumpHost)
            }
            pendingHostKeyReplacement =
                Self.agreed(candidates)
                ?? jumpHostCandidates.lazy.compactMap { candidate in
                    Self.agreed(jumpHostCandidates.filter { $0.jumpHost == candidate.jumpHost })
                }.first
        default:
            return
        }
    }

    /// The replacement every candidate agrees on, if any.
    private static func agreed(_ candidates: [HostKeyReplacement]) -> HostKeyReplacement? {
        guard let first = candidates.first, candidates.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }

    /// Runs an endpoint Host's session list as its launcher probe, before
    /// ping. The sessions are discarded: the endpoint's socket already names
    /// the one this Host uses. nil means the launcher answered like herdr.
    private func launcherProbeFailure(
        _ endpoint: HerdrEndpoint, over transport: any Transport
    ) async -> PreflightReport? {
        do {
            _ = try await transport.listSessions()
            return nil
        } catch TransportError.malformedResponse(let detail) {
            return .failure(
                check: .herdrInstalled,
                hint: String(
                    localized: "The herdr launcher at \(endpoint.executablePath) did not answer like herdr. (\(detail))"))
        } catch {
            guard !Task.isCancelled else { return nil }
            captureHostKeyReplacement(error)
            return failureReport(error)
        }
    }

    private func failureReport(_ error: any Error) -> PreflightReport {
        overlayLoginURL = (error as? TransportError)?.overlayLoginURL
        return if let transportError = error as? TransportError {
            .failure(
                transportError, authMethod: host.authMethod,
                usesHerdrEndpoint: host.herdrEndpoint != nil)
        } else {
            .failure(
                check: .connection,
                hint: String(localized: "The connection failed unexpectedly. (\(String(describing: error)))"))
        }
    }

    private func awaitFingerprintDecision(for candidate: HostKeyCandidate, run: UUID) async -> Bool {
        // A cancelled run's late handshake never asks the user.
        guard currentRun == run else { return false }
        // The transport asks about one key at a time, even while routes
        // race; decline a second defensively instead of leaking the first
        // continuation.
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
