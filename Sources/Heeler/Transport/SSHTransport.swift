// @preconcurrency: Citadel predates strict concurrency and SSHClient is not
// marked Sendable; its async methods hop off the actor executor, which would
// otherwise be an error. The actor still serializes all access to the client.
@preconcurrency import Citadel
import Foundation
import Logging
import NIOCore
@preconcurrency import NIOSSH

private enum TerminalAttachPumpError: Error, Sendable {
    case input(String)
    case output(String)
}

/// How a Host connection locates the remote socat executable.
///
/// Two levels only: the Host's configured path, then whatever the Host's own
/// PATH resolves `socat` to. There is deliberately no built-in list of
/// package-manager prefixes — such a list is a bet on specific distro layouts
/// that rots with every packaging change, and it can only ever name locations
/// that are already on PATH anyway.
enum SocatDiscovery: Sendable, Equatable {
    /// The configured path first, then `command -v socat` on the Host.
    case automatic
    /// The configured path and nothing else. Keeps the "socat is absent" case
    /// reproducible in tests, which run against machines that do have it.
    case configuredPathOnly
}

/// How to reach one Host, authenticate against it, and find its herdr socket.
struct SSHTransportSettings: Sendable {
    static let defaultSessionListCommand = "herdr session list --json"
    static let agentAvailabilityMarker = "__HEELER_AGENT_KIND__="

    /// The Heeler plugin (ADR 0007/0008) whose config dir holds the
    /// Notification Registration file.
    static let notificationPluginID = "heeler.pairing"

    var host: String
    var port: Int
    var username: String
    var credentials: SSHCredentials
    /// TOFU host key policy (#2): the trusted-fingerprint store plus the
    /// first-connect confirmation the UI implements.
    var hostKeyPolicy: HostKeyPolicy
    /// Which herdr socket to reach on the Host.
    var socket: HerdrSocketLocation
    /// Preferred absolute path of socat on the Host, tried before anything
    /// else. Execution never relies on the login shell resolving `socat`: the
    /// path discovery settles on is absolute, so PATH is consulted at most
    /// once per connection and never again (ADR 0002).
    var socatPath: String
    /// How to locate socat when the preferred path is not executable.
    var socatDiscovery: SocatDiscovery = .automatic
    /// Optional Jump Host. When set, the Transport authenticates against the
    /// jump host first and opens the Host connection through it, so the Host
    /// needs no inbound reachability of its own. nil is a direct connection.
    var jump: SSHJumpSettings? = nil
    /// Command that wakes a stopped herdr server, run over a no-PTY exec
    /// channel when a request hits connection-refused (#6). The default is
    /// the strategy from spec #16: `herdr remote-client-bridge` ensures the
    /// server is running (spawn + wait for socket) before bridging, then
    /// exits on stdin EOF. Injectable so tests can substitute a script at
    /// the environment boundary; per-Host override also covers hosts where
    /// herdr is not on the login shell's PATH.
    var wakeCommand: String = "herdr remote-client-bridge"
    /// Official Host-local CLI command for discovering default and named
    /// sessions. It does not depend on a running API socket.
    var sessionListCommand: String = Self.defaultSessionListCommand
    /// Host-local availability probe for the protocol's canonical interactive
    /// Agent executables. It emits marker-delimited canonical kinds so login
    /// shell noise cannot become a false positive. Injectable only at the
    /// environment boundary for real-SSH tests.
    var agentDiscoveryCommand: String = Self.defaultAgentDiscoveryCommand
    /// Command that attaches interactively to a Pane, run on the Host's
    /// dedicated terminal channel with a PTY (#11); the attach target and
    /// takeover flag are appended (see `attachBootstrapLine`). Injectable so
    /// tests can substitute a script at the environment boundary; per-Host
    /// override also covers hosts where herdr is not on the login shell's
    /// PATH.
    var attachCommand: String = "herdr agent attach"
    /// Command used to print a marker-delimited remote home directory. It is
    /// injectable only at the environment boundary for real-SSH tests.
    var homeCommand: String = "printf '__HEELER_HOME__=%s\\n' \"$HOME\""
    /// Creates one private directory beneath the Host operating system's
    /// selected temporary root. The marker makes login-shell noise harmless;
    /// callers never interpolate image names or paths into this command.
    var stageDirectoryCommand: String =
        "/bin/sh -c 'umask 077; "
        + "directory=$(mktemp -d \"${TMPDIR:-/tmp}/heeler.XXXXXXXX\") || exit 1; "
        + "printf \"__HEELER_STAGE_DIR__=%s\\n\" \"$directory\"'"
    /// Official Host-local CLI for listing installed plugins (offline, like
    /// session discovery). Notification Registration gates on the
    /// Heeler plugin being installed and enabled before touching its
    /// config dir — `herdr plugin config-dir` happily prints (and creates) a
    /// directory for any id, so it cannot carry the "is it installed" check.
    var pluginListCommand: String = "herdr plugin list --json"
    /// Prints the marker-delimited config dir of the Heeler plugin;
    /// herdr creates the directory if missing. Runs under POSIX sh because
    /// login shells do not share substitution syntax; the marker makes
    /// login-shell noise harmless.
    var notificationConfigDirCommand: String =
        "/bin/sh -c 'printf \"__HEELER_PLUGIN_CONFIG_DIR__=%s\\n\" "
        + "\"$(herdr plugin config-dir \(SSHTransportSettings.notificationPluginID))\"'"
    /// Per-request deadline covering the queue wait and the exec exchange;
    /// on expiry the request fails with `.timedOut` and its channel is
    /// closed. Short in tests, generous by default: a hung host should
    /// degrade gracefully, a slow one should still answer.
    var requestTimeout: Duration = .seconds(15)

    static var defaultAgentDiscoveryCommand: String {
        let checks = SupportedAgentKind.allCases.map { kind in
            "command -v \(kind.executable) >/dev/null 2>&1"
                + " && printf \"\(agentAvailabilityMarker)%s\\n\" \"\(kind.rawValue)\""
        }
        return "/bin/sh -c '\(checks.joined(separator: "; ")); exit 0'"
    }
}

/// The Jump Host in front of a Host: its own coordinates and credentials. Its
/// host key is verified under the same TOFU policy as the Host's, keyed by
/// its own endpoint, so both hops must be confirmed before either is trusted.
///
/// The Host's `address`/`port` are resolved from the Jump Host, which is
/// normally a loopback port held open by a reverse tunnel. Two Hosts behind
/// one Jump Host therefore need distinct tunnel ports: known-hosts entries are
/// keyed by endpoint, so a shared `127.0.0.1:12222` would collide.
struct SSHJumpSettings: Sendable {
    var host: String
    var port: Int
    var username: String
    var credentials: SSHCredentials

    init(host: String, port: Int = 22, username: String, credentials: SSHCredentials) {
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
    }
}

private struct HerdrSessionListResponse: Decodable {
    let sessions: [HerdrSession]
}

/// Transport over SSH exec channels running `socat - UNIX-CONNECT:<sock>`,
/// one channel per request because herdr serves one request per connection
/// (ADR 0002). An actor because Citadel's SSHClient is not Sendable.
actor SSHTransport: Transport {
    /// The herdr wire protocol version this build speaks (herdr 0.7.5).
    static let supportedProtocolVersion = 17

    /// Citadel logs full SFTP paths at info, debug, and trace levels. Staging
    /// paths are private diagnostics data, so every SFTP channel uses a
    /// per-instance sink rather than Citadel's stderr-backed default logger.
    private static let restrictedSFTPLogger = Logger(
        label: "dev.bybee.heeler.sftp",
        factory: { _ in SwiftLogNoOpLogHandler() })

    /// Exec channels are SSH session channels, capped by sshd's MaxSessions
    /// (default 10) per connection. Bound at 8 to leave headroom for the
    /// events channel and the interactive terminal.
    static let maxConcurrentExecChannels = SSHChannelBudget.defaultOrdinaryChannelCapacity

    private let client: SSHClient
    /// The outer connection owns the direct-tcpip channel carrying `client`.
    /// Citadel requires both clients to be closed explicitly.
    private let jumpClient: SSHClient?
    private let socketLocation: HerdrSocketLocation
    private let preferredSocatPath: String
    private let socatDiscovery: SocatDiscovery
    private let wakeCommand: String
    private let sessionListCommand: String
    private let agentDiscoveryCommand: String
    private let attachCommand: String
    private let homeCommand: String
    private let stageDirectoryCommand: String
    private let pluginListCommand: String
    private let notificationConfigDirCommand: String
    private let requestTimeout: Duration
    private let execChannelBudget: SSHChannelBudget
    /// Remote home directory resolution, resolved over exec once per Host:
    /// concurrent first requests share one in-flight run, success is cached
    /// for the connection's lifetime, failure is not (the next request
    /// retries).
    private let homeDirectory = SharedAsyncOperation<String>(cachesSuccess: true)
    /// The remote socat executable, resolved over exec once per connection
    /// like the home directory. Failure is not cached: installing socat and
    /// retrying must work on the same connection.
    private let socatExecutable = SharedAsyncOperation<String>(cachesSuccess: true)
    /// The Heeler plugin's config dir, resolved over exec once per
    /// Host like the home directory. Failure (plugin missing, probe broken)
    /// is not cached: installing the plugin and retrying must work on the
    /// same connection.
    private let notificationConfigDirectory = SharedAsyncOperation<String>(cachesSuccess: true)
    /// Cold-start wake; concurrent refused requests share one wake instead
    /// of racing exec channels, and a later cold start wakes again.
    private let wake = SharedAsyncOperation<Void>(cachesSuccess: false)

    /// Active SFTP channels keyed by staging operation. Cancellation closes
    /// the exact channel so a blocked Citadel request cannot continue after
    /// the app reports an interrupted upload.
    private var imageStageClients: [UUID: SFTPClient] = [:]

    private init(
        client: SSHClient, jumpClient: SSHClient?, socketLocation: HerdrSocketLocation,
        preferredSocatPath: String, socatDiscovery: SocatDiscovery,
        wakeCommand: String, sessionListCommand: String, agentDiscoveryCommand: String,
        attachCommand: String,
        homeCommand: String, stageDirectoryCommand: String,
        pluginListCommand: String, notificationConfigDirCommand: String,
        requestTimeout: Duration
    ) {
        self.client = client
        self.jumpClient = jumpClient
        self.socketLocation = socketLocation
        self.preferredSocatPath = preferredSocatPath
        self.socatDiscovery = socatDiscovery
        self.wakeCommand = wakeCommand
        self.sessionListCommand = sessionListCommand
        self.agentDiscoveryCommand = agentDiscoveryCommand
        self.attachCommand = attachCommand
        self.homeCommand = homeCommand
        self.stageDirectoryCommand = stageDirectoryCommand
        self.pluginListCommand = pluginListCommand
        self.notificationConfigDirCommand = notificationConfigDirCommand
        self.requestTimeout = requestTimeout
        execChannelBudget = SSHChannelBudget(capacity: Self.maxConcurrentExecChannels)
    }

    /// Connects, verifies the host key per the TOFU policy, and
    /// authenticates — but sends nothing yet: callers must `ping` first to
    /// verify the protocol version.
    static func connect(settings: SSHTransportSettings) async throws -> SSHTransport {
        let clients: (target: SSHClient, jump: SSHClient?)
        if let jump = settings.jump {
            clients = try await connectThroughJumpHost(jump, settings: settings)
        } else {
            clients = (try await connectDirectly(settings: settings), nil)
        }
        return SSHTransport(
            client: clients.target, jumpClient: clients.jump, socketLocation: settings.socket,
            preferredSocatPath: settings.socatPath, socatDiscovery: settings.socatDiscovery,
            wakeCommand: settings.wakeCommand, sessionListCommand: settings.sessionListCommand,
            agentDiscoveryCommand: settings.agentDiscoveryCommand,
            attachCommand: settings.attachCommand, homeCommand: settings.homeCommand,
            stageDirectoryCommand: settings.stageDirectoryCommand,
            pluginListCommand: settings.pluginListCommand,
            notificationConfigDirCommand: settings.notificationConfigDirCommand,
            requestTimeout: settings.requestTimeout)
    }

    private static func connectDirectly(settings: SSHTransportSettings) async throws -> SSHClient {
        let validator = TOFUHostKeyValidator(
            host: settings.host, port: settings.port, policy: settings.hostKeyPolicy)
        do {
            return try await SSHClient.connect(
                host: settings.host,
                port: settings.port,
                authenticationMethod: settings.credentials.citadelMethod(
                    username: settings.username),
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
        } catch {
            // NIOSSH may wrap the validator's error on its way out of the
            // handshake; the recorded verdict is the source of truth.
            if let hostKeyFailure = validator.failure {
                throw hostKeyFailure
            }
            throw Self.classifyConnectFailure(error)
        }
    }

    /// Authenticates against the Jump Host, then opens the Host connection over
    /// a direct-tcpip channel through it. Both hops run the same TOFU policy
    /// against their own endpoints; the Host hop's session keys are negotiated
    /// end to end, so the Jump Host forwards ciphertext it cannot read.
    ///
    /// First-hop failures are wrapped in `.jumpHostFailed` so the UI can name
    /// the Jump Host rather than blaming the Host.
    private static func connectThroughJumpHost(
        _ jump: SSHJumpSettings, settings: SSHTransportSettings
    ) async throws -> (target: SSHClient, jump: SSHClient) {
        let jumpValidator = TOFUHostKeyValidator(
            host: jump.host, port: jump.port, policy: settings.hostKeyPolicy)
        let hop: SSHClient
        do {
            hop = try await SSHClient.connect(
                host: jump.host,
                port: jump.port,
                authenticationMethod: jump.credentials.citadelMethod(username: jump.username),
                hostKeyValidator: .custom(jumpValidator),
                reconnect: .never
            )
        } catch {
            throw TransportError.jumpHostFailed(
                jumpValidator.failure ?? Self.classifyConnectFailure(error))
        }

        let validator = TOFUHostKeyValidator(
            host: settings.host, port: settings.port, policy: settings.hostKeyPolicy)
        do {
            let target = try await hop.jump(
                to: SSHClientSettings(
                    host: settings.host,
                    port: settings.port,
                    authenticationMethod: {
                        settings.credentials.citadelMethod(username: settings.username)
                    },
                    hostKeyValidator: .custom(validator)))
            return (target, hop)
        } catch {
            try? await hop.close()
            if let hostKeyFailure = validator.failure {
                throw hostKeyFailure
            }
            throw Self.classifyConnectFailure(error)
        }
    }

    /// Maps connect-time failures onto the taxonomy: credential rejection is
    /// actionable ("fix your key/password"), everything else is a Host that
    /// could not be reached.
    private static func classifyConnectFailure(_ error: any Error) -> TransportError {
        switch error {
        case SSHClientError.allAuthenticationOptionsFailed,
            SSHClientError.unsupportedPasswordAuthentication,
            SSHClientError.unsupportedPrivateKeyAuthentication,
            SSHClientError.unsupportedHostBasedAuthentication:
            return .authenticationFailed
        default:
            return .sshUnreachable(detail: String(describing: error))
        }
    }

    func ping() async throws -> ServerInfo {
        let pong = try await request(method: "ping", decoding: PongResponse.self)
        guard pong.protocolVersion == Self.supportedProtocolVersion else {
            throw TransportError.protocolVersionMismatch(
                server: pong.protocolVersion, supported: Self.supportedProtocolVersion)
        }
        return ServerInfo(version: pong.version, protocolVersion: pong.protocolVersion)
    }

    func listSessions() async throws -> [HerdrSession] {
        let output = try await withRequestDeadline(requestTimeout) {
            try await self.runHostCommand(self.sessionListCommand)
        }
        let sessions: [HerdrSession]
        do {
            sessions = try JSONDecoder().decode(HerdrSessionListResponse.self, from: output).sessions
        } catch {
            throw TransportError.malformedResponse(
                "herdr session list returned invalid JSON: \(Self.preview(output))")
        }
        guard sessions.allSatisfy({ HerdrSessionName.isValid($0.name) }) else {
            throw TransportError.malformedResponse(
                "herdr session list returned an invalid session name")
        }
        return sessions
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        let output = try await withRequestDeadline(requestTimeout) {
            try await self.runHostCommand(self.agentDiscoveryCommand)
        }
        let discovered = Set(
            String(decoding: output, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> SupportedAgentKind? in
                    guard line.hasPrefix(SSHTransportSettings.agentAvailabilityMarker) else {
                        return nil
                    }
                    return SupportedAgentKind(
                        rawValue: String(
                            line.dropFirst(
                                SSHTransportSettings.agentAvailabilityMarker.count)))
                })
        return SupportedAgentKind.allCases.filter(discovered.contains)
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        let sources = SkillSourceCatalog.sources(for: query.kind)
        guard !sources.isEmpty else { return [] }
        let home = try await remoteHomeDirectory()
        let resolved = sources.compactMap { source -> SkillProbe.ResolvedSource? in
            let root: String?
            switch source.root {
            case .home: root = home
            case .project: root = query.projectRoot
            }
            // A root that cannot be quoted safely skips its sources rather
            // than failing the probe: the global half of the pane still works
            // when a project path is exotic.
            guard let root, !root.isEmpty else { return nil }
            let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
            guard
                let quoted = RemoteShellPath.quotedAbsolute(
                    "\(trimmed)/\(source.relativePath)")
            else { return nil }
            return SkillProbe.ResolvedSource(
                scope: source.scope, quotedDirectory: quoted,
                layout: source.layout, commandPrefix: source.commandPrefix)
        }
        guard !resolved.isEmpty else { return [] }
        let command = SkillProbe.command(for: resolved)
        let output = try await withRequestDeadline(requestTimeout) {
            try await self.runHostCommand(command)
        }
        return SkillProbe.skills(fromProbeOutput: output, sources: resolved)
    }

    func readSkillFile(atPath path: String) async throws -> String {
        guard let quoted = RemoteShellPath.quotedAbsolute(path) else {
            throw TransportError.channelFailed(detail: "skill path is not quotable")
        }
        let output = try await withRequestDeadline(requestTimeout) {
            try await self.runHostCommand(SkillProbe.readFileCommand(quotedPath: quoted))
        }
        guard let content = SkillProbe.documentContent(in: output) else {
            throw TransportError.malformedResponse(
                "The skill file is gone or unreadable on the Host.")
        }
        return content
    }

    private func runHostCommand(_ command: String) async throws -> Data {
        try await execChannelBudget.withChannel {
            do {
                let output = try await self.client.executeCommand(
                    Self.cLocaleCommand(command))
                return Data(output.readableBytesView)
            } catch is CancellationError {
                throw TransportError.cancelled
            } catch {
                throw TransportError.channelFailed(detail: String(describing: error))
            }
        }
    }

    func listAgents() async throws -> [Agent] {
        try await request(method: "agent.list", decoding: AgentListResponse.self)
            .agents.map(Agent.init)
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        try await request(method: "session.snapshot", decoding: SessionSnapshotResponse.self)
            .snapshot
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        try await request(method: "pane.read", params: params, decoding: PaneReadResponse.self)
            .read
    }

    func startAgent(_ launch: AgentLaunchRequest) async throws -> Agent {
        let created = try await request(
            method: "tab.create",
            params: TabCreateParams(
                cwd: launch.cwd, focus: false, workspaceID: launch.workspaceID),
            decoding: TabCreatedResponse.self)
        do {
            let response = try await startAgentAwaitingShell(
                launch, paneID: created.rootPane.paneID)
            return Agent(response.agent)
        } catch let error as HerdrAPIError {
            // A definitive rejection must not leave the fresh empty tab behind.
            // Transport failures are ambiguous: the agent may have started even
            // if its reply was lost, so preserving the pane is safer there.
            try? await closePane(PaneTarget(paneID: created.rootPane.paneID))
            throw error
        } catch is CancellationError {
            // Only thrown between readiness retries, after a definitive
            // rejection — no agent is running in the fresh pane for sure.
            try? await closePane(PaneTarget(paneID: created.rootPane.paneID))
            throw CancellationError()
        }
    }

    func startAgentInNewWorktree(
        _ launch: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        let created = try await request(
            method: "worktree.create",
            params: WorktreeCreateParams(
                base: worktree.base,
                branch: worktree.branch,
                focus: false,
                workspaceID: launch.workspaceID),
            decoding: WorktreeCreatedResponse.self)
        do {
            let response = try await startAgentAwaitingShell(
                launch, paneID: created.rootPane.paneID)
            return Agent(response.agent)
        } catch let error as HerdrAPIError {
            // Same teardown contract as startAgent: a definitive rejection
            // must not leave the fresh checkout and workspace behind.
            // worktree.remove deletes the checkout and closes the workspace
            // in one call; the local branch survives.
            try? await removeWorktree(workspaceID: created.workspace.workspaceID)
            throw error
        } catch is CancellationError {
            // Only thrown between readiness retries, after a definitive
            // rejection — no agent runs in the fresh pane for sure. The task
            // is already cancelled here, so the remove is best-effort: it may
            // itself be cut short and strand the checkout.
            try? await removeWorktree(workspaceID: created.workspace.workspaceID)
            throw CancellationError()
        }
    }

    /// Cleanup path for a worktree launch whose agent.start was definitively
    /// rejected. The checkout is minutes old and untouched, so the
    /// non-forced remove is safe.
    private func removeWorktree(workspaceID: String) async throws {
        _ = try await request(
            method: "worktree.remove",
            params: WorktreeRemoveParams(workspaceID: workspaceID),
            decoding: WorktreeRemovedResponse.self)
    }

    /// herdr (0.7.5+) rejects `agent.start` with `agent_pane_busy` until the
    /// fresh pane's shell reaches its interactive prompt; shell boot takes a
    /// few seconds on some hosts. The pane is ours and empty, so that code
    /// can only mean "not ready yet" — retry briefly before giving up.
    private func startAgentAwaitingShell(
        _ launch: AgentLaunchRequest, paneID: String
    ) async throws -> AgentStartedResponse {
        let params = AgentStartParams(
            kind: launch.kind,
            name: launch.name,
            paneID: paneID,
            args: launch.arguments.isEmpty ? nil : launch.arguments)
        let deadline = ContinuousClock.now + Self.shellReadinessBudget
        while true {
            do {
                return try await request(
                    method: "agent.start", params: params,
                    decoding: AgentStartedResponse.self)
            } catch let error as HerdrAPIError where error.code == "agent_pane_busy" {
                guard ContinuousClock.now + Self.shellReadinessRetryDelay < deadline else {
                    throw error
                }
                try await Task.sleep(for: Self.shellReadinessRetryDelay)
            }
        }
    }

    private static let shellReadinessBudget: Duration = .seconds(10)
    private static let shellReadinessRetryDelay: Duration = .milliseconds(500)

    func closePane(_ params: PaneTarget) async throws {
        _ = try await request(method: "pane.close", params: params, decoding: OkResponse.self)
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        _ = try await request(
            method: "agent.rename", params: params, decoding: AgentInfoResponse.self)
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        _ = try await request(
            method: "workspace.rename", params: params, decoding: WorkspaceInfoResponse.self)
    }

    // MARK: Image staging

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws -> StagedImage {
        guard
            image.byteCount > 0,
            image.byteCount <= Int64(ImagePreparer.maximumEncodedByteCount),
            let localSize = try? FileManager.default.attributesOfItem(
                atPath: image.fileURL.path)[.size] as? NSNumber,
            localSize.int64Value == image.byteCount
        else {
            throw ImageStagingError.invalidPreparedImage
        }
        guard client.isConnected else {
            throw ImageStagingError.transferFailed
        }

        do {
            return try await execChannelBudget.withChannel {
                try Task.checkCancellation()
                let remoteDirectory = try await self.createStageDirectory()
                let operationID = UUID()
                await progress(
                    ImageStageProgress(transferredBytes: 0, totalBytes: image.byteCount))

                return try await withTaskCancellationHandler {
                    try await self.performImageStage(
                        image,
                        remoteDirectory: remoteDirectory,
                        operationID: operationID,
                        progress: progress)
                } onCancel: {
                    Task { await self.cancelImageStage(operationID) }
                }
            }
        } catch let error as ImageStagingError {
            throw error
        } catch is CancellationError {
            throw ImageStagingError.cancelled
        } catch {
            throw Task.isCancelled
                ? ImageStagingError.cancelled : ImageStagingError.transferFailed
        }
    }

    private func createStageDirectory() async throws -> String {
        let output: ByteBuffer
        do {
            output = try await client.executeCommand(
                Self.cLocaleCommand(stageDirectoryCommand))
        } catch {
            if Task.isCancelled {
                throw ImageStagingError.cancelled
            }
            throw client.isConnected
                ? ImageStagingError.remoteTemporaryDirectoryFailed
                : ImageStagingError.transferFailed
        }
        return try Self.parseStageDirectory(output)
    }

    private func performImageStage(
        _ image: PreparedImage,
        remoteDirectory: String,
        operationID: UUID,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws -> StagedImage {
        let sftp: SFTPClient
        do {
            sftp = try await client.openSFTP(logger: Self.restrictedSFTPLogger)
        } catch {
            if Task.isCancelled {
                throw ImageStagingError.cancelled
            }
            throw client.isConnected
                ? ImageStagingError.sftpUnavailable : ImageStagingError.transferFailed
        }
        imageStageClients[operationID] = sftp

        let randomName = UUID().uuidString.lowercased()
        let finalPath = "\(remoteDirectory)/\(randomName).\(image.format.fileExtension)"
        var partPath: String? = "\(finalPath).part"

        do {
            let directoryAttributes = try await sftp.getAttributes(at: remoteDirectory)
            guard Self.permissionBits(directoryAttributes.permissions) == 0o700 else {
                throw ImageStagingError.permissionEnforcementFailed
            }
            guard let currentPartPath = partPath else {
                throw ImageStagingError.transferFailed
            }
            try await streamImage(
                image,
                to: currentPartPath,
                over: sftp,
                progress: progress)
            try Task.checkCancellation()

            let uploadedAttributes = try await sftp.getAttributes(at: currentPartPath)
            guard
                uploadedAttributes.size == UInt64(image.byteCount),
                Self.permissionBits(uploadedAttributes.permissions) == 0o600
            else {
                throw ImageStagingError.byteCountMismatch
            }
            try await sftp.rename(at: currentPartPath, to: finalPath)
            partPath = nil

            let finalAttributes = try await sftp.getAttributes(at: finalPath)
            guard
                finalAttributes.size == UInt64(image.byteCount),
                Self.permissionBits(finalAttributes.permissions) == 0o600
            else {
                // Rename completed, so ADR 0005 forbids deleting this final
                // Host file even when the final verification response is bad.
                throw ImageStagingError.byteCountMismatch
            }
            let staged = try StagedImage(path: finalPath)
            imageStageClients[operationID] = nil
            try await sftp.close()
            return staged
        } catch {
            imageStageClients[operationID] = nil
            try? await sftp.close()
            if let partPath {
                await bestEffortRemoveRemoteFile(at: partPath)
            }
            if Task.isCancelled {
                throw ImageStagingError.cancelled
            }
            if let stagingError = error as? ImageStagingError {
                throw stagingError
            }
            throw ImageStagingError.transferFailed
        }
    }

    private func streamImage(
        _ image: PreparedImage,
        to remotePath: String,
        over sftp: SFTPClient,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws {
        let localFile: FileHandle
        do {
            localFile = try FileHandle(forReadingFrom: image.fileURL)
        } catch {
            throw ImageStagingError.localReadFailed
        }
        defer { try? localFile.close() }

        var creationAttributes = SFTPFileAttributes()
        creationAttributes.permissions = 0o600
        let remoteFile = try await sftp.openFile(
            filePath: remotePath,
            flags: [.write, .create, .forceCreate],
            attributes: creationAttributes)
        do {
            let attributes = try await remoteFile.readAttributes()
            guard Self.permissionBits(attributes.permissions) == 0o600 else {
                throw ImageStagingError.permissionEnforcementFailed
            }

            let chunkSize = 64 * 1_024
            var transferred: Int64 = 0
            while transferred < image.byteCount {
                try Task.checkCancellation()
                let remaining = image.byteCount - transferred
                let requested = min(chunkSize, Int(remaining))
                guard
                    let data = try localFile.read(upToCount: requested),
                    !data.isEmpty
                else {
                    throw ImageStagingError.byteCountMismatch
                }
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await remoteFile.write(buffer, at: UInt64(transferred))
                transferred += Int64(data.count)
                await progress(
                    ImageStageProgress(
                        transferredBytes: transferred,
                        totalBytes: image.byteCount))
            }
            guard try localFile.read(upToCount: 1)?.isEmpty != false else {
                throw ImageStagingError.byteCountMismatch
            }
            try await remoteFile.close()
        } catch {
            try? await remoteFile.close()
            throw error
        }
    }

    private func cancelImageStage(_ operationID: UUID) async {
        guard let sftp = imageStageClients[operationID] else { return }
        try? await sftp.close()
    }

    private func bestEffortRemoveRemoteFile(at path: String) async {
        guard
            let sftp = try? await client.openSFTP(logger: Self.restrictedSFTPLogger)
        else { return }
        try? await sftp.remove(at: path)
        try? await sftp.close()
    }

    private static func permissionBits(_ permissions: UInt32?) -> UInt32? {
        permissions.map { $0 & 0o777 }
    }

    // MARK: Notification plugin config files (#72, #76)
    //
    // Both the registration file (notifications.json, registration file v1)
    // and the plugin config (notify.json, the custom Push Relay base URL)
    // live inside the Heeler plugin's config dir (plugin/README.md).
    // Writes are atomic: the content lands in a same-directory temp file over
    // SFTP, then one exec `mv -f` renames it over the live file — SFTP v3
    // RENAME refuses to overwrite, and mv on the same filesystem is a rename
    // syscall. Both files share the plugin gate and the atomic-replace dance.

    static let notificationRegistrationFileName = "notifications.json"
    static let notificationConfigFileName = "notify.json"

    func readNotificationRegistration() async throws -> Data? {
        try await readPluginConfigFile(named: Self.notificationRegistrationFileName)
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        try await replacePluginConfigFile(
            named: Self.notificationRegistrationFileName, contents: contents)
    }

    func readNotificationConfig() async throws -> Data? {
        try await readPluginConfigFile(named: Self.notificationConfigFileName)
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        try await replacePluginConfigFile(
            named: Self.notificationConfigFileName, contents: contents)
    }

    private func readPluginConfigFile(named name: String) async throws -> Data? {
        try await withRequestDeadline(requestTimeout) {
            let path = try await self.pluginConfigFilePath(named: name)
            return try await self.execChannelBudget.withChannel {
                try await self.readPluginFile(at: path)
            }
        }
    }

    private func replacePluginConfigFile(named name: String, contents: Data) async throws {
        try await withRequestDeadline(requestTimeout) {
            let path = try await self.pluginConfigFilePath(named: name)
            let temporaryPath = "\(path).tmp-\(UUID().uuidString.lowercased())"
            guard
                let quotedTemporary = RemoteShellPath.quotedAbsolute(temporaryPath),
                let quotedFinal = RemoteShellPath.quotedAbsolute(path)
            else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The plugin config path cannot be quoted for the remote shell.")
            }
            try await self.execChannelBudget.withChannel {
                try await self.writePluginTemporaryFile(contents, at: temporaryPath)
            }
            do {
                try await self.execChannelBudget.withChannel {
                    _ = try await self.client.executeCommand(
                        Self.cLocaleCommand("mv -f \(quotedTemporary) \(quotedFinal)"))
                }
            } catch {
                await self.bestEffortRemoveRemoteFile(at: temporaryPath)
                if error is CancellationError { throw TransportError.cancelled }
                throw NotificationRegistrationError.writeFailed(
                    detail: String(describing: error))
            }
        }
    }

    private func readPluginFile(at path: String) async throws -> Data? {
        let sftp: SFTPClient
        do {
            sftp = try await client.openSFTP(logger: Self.restrictedSFTPLogger)
        } catch {
            if error is CancellationError { throw TransportError.cancelled }
            throw NotificationRegistrationError.readFailed(detail: String(describing: error))
        }
        do {
            let file: SFTPFile
            do {
                file = try await sftp.openFile(filePath: path, flags: .read)
            } catch let error where Self.isNoSuchFile(error) {
                // The plugin holds no such file yet (no device registered, or
                // no config written) — the caller reads nil as "start empty".
                try? await sftp.close()
                return nil
            }
            let buffer = try await file.readAll()
            try await file.close()
            try await sftp.close()
            return Data(buffer.readableBytesView)
        } catch {
            try? await sftp.close()
            if error is CancellationError { throw TransportError.cancelled }
            throw NotificationRegistrationError.readFailed(detail: String(describing: error))
        }
    }

    private func writePluginTemporaryFile(_ contents: Data, at path: String) async throws {
        let sftp: SFTPClient
        do {
            sftp = try await client.openSFTP(logger: Self.restrictedSFTPLogger)
        } catch {
            if error is CancellationError { throw TransportError.cancelled }
            throw NotificationRegistrationError.writeFailed(detail: String(describing: error))
        }
        do {
            var creationAttributes = SFTPFileAttributes()
            creationAttributes.permissions = 0o600
            let file = try await sftp.openFile(
                filePath: path,
                flags: [.write, .create, .forceCreate],
                attributes: creationAttributes)
            do {
                var buffer = ByteBufferAllocator().buffer(capacity: contents.count)
                buffer.writeBytes(contents)
                try await file.write(buffer, at: 0)
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
            try await sftp.close()
        } catch {
            try? await sftp.close()
            if error is CancellationError { throw TransportError.cancelled }
            throw NotificationRegistrationError.writeFailed(detail: String(describing: error))
        }
    }

    /// Whether an SFTP failure means "the file does not exist". Citadel
    /// surfaces the raw `SFTPMessage.Status` from `openFile` (and wraps
    /// other statuses in `SFTPError.errorStatus`), so both shapes count.
    private static func isNoSuchFile(_ error: any Error) -> Bool {
        switch error {
        case let status as SFTPMessage.Status:
            status.errorCode == .noSuchFile
        case SFTPError.errorStatus(let status):
            status.errorCode == .noSuchFile
        default:
            false
        }
    }

    private func pluginConfigFilePath(named name: String) async throws -> String {
        let directory = try await notificationConfigDirectory.value {
            try await self.resolveNotificationConfigDirectory()
        }
        return "\(directory)/\(name)"
    }

    /// Verifies the plugin is installed, then resolves its config dir over
    /// exec. Order matters: `herdr plugin config-dir` prints (and creates) a
    /// directory for any id whatsoever, so it cannot detect absence itself.
    private func resolveNotificationConfigDirectory() async throws -> String {
        let listOutput = try await runRegistrationProbe(command: pluginListCommand)
        try requireNotificationPlugin(in: listOutput)
        let output = try await runRegistrationProbe(command: notificationConfigDirCommand)
        guard
            let directory = Self.markerValue(
                in: output, prefix: Self.pluginConfigDirOutputPrefix),
            RemoteShellPath.isQuotableAbsolute(directory)
        else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "config-dir command printed: \(Self.preview(output))")
        }
        return directory
    }

    private func requireNotificationPlugin(in listOutput: Data) throws {
        let list: PluginListEnvelope
        do {
            list = try JSONDecoder().decode(PluginListEnvelope.self, from: listOutput)
        } catch {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "plugin list returned invalid JSON: \(Self.preview(listOutput))")
        }
        let installed = list.result.plugins.contains { plugin in
            plugin.pluginID == SSHTransportSettings.notificationPluginID
                && plugin.enabled != false
        }
        guard installed else {
            throw NotificationRegistrationError.pluginNotInstalled
        }
    }

    private func runRegistrationProbe(command: String) async throws -> Data {
        try await execChannelBudget.withChannel {
            do {
                let output = try await self.client.executeCommand(
                    Self.cLocaleCommand(command))
                return Data(output.readableBytesView)
            } catch is CancellationError {
                throw TransportError.cancelled
            } catch {
                throw NotificationRegistrationError.pluginProbeFailed(
                    detail: String(describing: error))
            }
        }
    }

    /// `herdr plugin list --json` envelope, parsed leniently: entries
    /// missing the fields we key on are skipped, not fatal.
    private struct PluginListEnvelope: Decodable {
        struct ResultBody: Decodable {
            let plugins: [Entry]
        }

        struct Entry: Decodable {
            let pluginID: String?
            let enabled: Bool?

            private enum CodingKeys: String, CodingKey {
                case pluginID = "plugin_id"
                case enabled
            }
        }

        let result: ResultBody
    }

    // MARK: Events channel (#4)
    //
    // One dedicated long-lived exec+socat channel per Host holds the
    // events.subscribe stream: one ack line, then event lines until the
    // channel is closed explicitly. It is exempt from the exec-slot queue —
    // the queue's bound of 8 exists precisely to leave MaxSessions headroom
    // for this channel (and a future Attach terminal) — and the state below
    // keeps it to exactly one channel per Host.

    private enum EventsChannelState: Equatable {
        case idle
        /// A subscribe call is setting the channel up (including a cold-start
        /// wake retry); further subscribes are refused meanwhile.
        case opening
        case streaming(readerID: UInt64)
    }

    private var eventsChannelState: EventsChannelState = .idle
    private var nextEventsReaderID: UInt64 = 0
    /// Readers that ended while the channel was still `.opening` (e.g. the
    /// remote closed right after the ack); the subscribe path reconciles so
    /// the state can never stick at `.streaming` for a dead reader.
    private var endedEventsReaders: Set<UInt64> = []

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        guard eventsChannelState == .idle else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        eventsChannelState = .opening
        do {
            let (stream, readerID) = try await withColdStartWake {
                try await self.openEventsChannel(subscriptions)
            }
            if endedEventsReaders.remove(readerID) != nil {
                // The reader already died (remote closed straight after the
                // ack); the stream the caller gets is finished, not live.
                eventsChannelState = .idle
            } else {
                eventsChannelState = .streaming(readerID: readerID)
            }
            return stream
        } catch {
            // openEventsChannel tears its reader down and awaits it before
            // throwing, so no live channel can outlast this reset.
            eventsChannelState = .idle
            throw error
        }
    }

    /// Opens the dedicated channel, sends the subscribe request, and waits
    /// for the ack line under the per-request deadline. On any failure the
    /// reader is torn down and awaited before the error propagates.
    private func openEventsChannel(_ subscriptions: [EventSubscription]) async throws
        -> (HerdrEventStream, readerID: UInt64)
    {
        let (socketPath, socatPath) = try await resolvedExchangePaths()
        let requestID = UUID().uuidString
        let requestLine = try HerdrWire.subscribeRequestLine(
            id: requestID, subscriptions: subscriptions)
        // Bounded event-path buffering (#22): under overflow the oldest
        // event is shed and the loss surfaces as a drop marker (see the
        // yield in runEventsChannel); the events session forwards it and
        // the Console resyncs from a snapshot. Sizing rationale lives on
        // HerdrEventStream.bufferLimit.
        let (events, eventContinuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(HerdrEventStream.bufferLimit))
        // Carries exactly one ack line and is finished right after it; one
        // slot is all it can ever hold.
        let (ackLines, ackContinuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        nextEventsReaderID += 1
        let readerID = nextEventsReaderID
        let readerTask = Task {
            await self.runEventsChannel(
                readerID: readerID, requestLine: requestLine, socketPath: socketPath,
                socatPath: socatPath,
                ack: ackContinuation, events: eventContinuation)
        }
        do {
            let ackLine = try await withRequestDeadline(requestTimeout) {
                var iterator = ackLines.makeAsyncIterator()
                guard let line = try await iterator.next() else {
                    throw TransportError.channelFailed(detail: "events channel ended before ack")
                }
                return line
            }
            _ = try HerdrWire.decodeResult(
                SubscriptionStartedResponse.self, fromResponseLine: ackLine, requestID: requestID)
        } catch {
            readerTask.cancel()
            await readerTask.value
            endedEventsReaders.remove(readerID)
            throw error
        }
        let stream = HerdrEventStream(events: events) {
            readerTask.cancel()
            await readerTask.value
        }
        return (stream, readerID)
    }

    /// The events channel's read loop: writes the subscribe request, hands
    /// the first stdout line to the ack stream, then yields every complete
    /// event line until the channel ends. Ending is always by explicit
    /// close: cancelling the reader task only ends the *local* inbound
    /// stream, the exec body then returns, Citadel closes the channel on the
    /// way out, and socat exits on stdin EOF. Takes no exec slot (see MARK).
    private func runEventsChannel(
        readerID: UInt64,
        requestLine: String,
        socketPath: String,
        socatPath: String,
        ack ackContinuation: AsyncThrowingStream<Data, any Error>.Continuation,
        events eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation
    ) async {
        var stderr = Data()
        var pending = Data()
        var sawAck = false
        /// nil means the stream ends gracefully (explicit `end()`).
        var streamFailure: TransportError?
        /// Backstop for an ack that never arrived; a finish after finish is
        /// a no-op, so this is only observed when the ack line never came.
        var ackFailure = TransportError.cancelled
        do {
            let command = try Self.socatCommand(socatPath: socatPath, socketPath: socketPath)
            try await client.withExec(command) {
                inbound, outbound in
                try? await outbound.write(ByteBuffer(string: requestLine))
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer):
                        pending.append(contentsOf: buffer.readableBytesView)
                        while let lineData = Self.takeLine(from: &pending) {
                            if !sawAck {
                                sawAck = true
                                ackContinuation.yield(lineData)
                                ackContinuation.finish()
                            } else if let event = HerdrWire.decodeEvent(fromLine: lineData) {
                                if case .dropped = eventContinuation.yield(event) {
                                    // The bounded buffer shed its oldest
                                    // event; one marker covers everything
                                    // shed before it, and a marker the
                                    // flood later sheds lands right back
                                    // here and is re-armed (see
                                    // HerdrEvent.eventsDropped).
                                    _ = eventContinuation.yield(.eventsDropped)
                                }
                            }
                            // Undecodable lines are dropped: junk on the
                            // stream must never kill it.
                        }
                    case .stderr(let buffer):
                        stderr.append(contentsOf: buffer.readableBytesView)
                    }
                }
            }
            if Task.isCancelled {
                // Explicit end(): the consumer closed the channel.
                streamFailure = nil
            } else if sawAck {
                streamFailure = TransportError.channelFailed(
                    detail: "events channel closed by remote")
            } else {
                ackFailure =
                    classifyExecFailure(stderr: stderr, socketPath: socketPath)
                    ?? TransportError.channelFailed(
                        detail:
                            "events channel closed before ack; stderr: \(Self.preview(stderr))")
                streamFailure = ackFailure
            }
        } catch is CancellationError {
            streamFailure = nil
        } catch {
            let failure =
                classifyExecFailure(stderr: stderr, socketPath: socketPath)
                ?? TransportError.channelFailed(
                    detail: "events channel: \(error); stderr: \(Self.preview(stderr))")
            ackFailure = failure
            streamFailure = failure
        }
        // State first, continuations second: a consumer resuming on the
        // stream's end must already see the channel as free.
        eventsChannelReaderDidEnd(readerID)
        ackContinuation.finish(throwing: ackFailure)
        if let streamFailure {
            eventContinuation.finish(throwing: streamFailure)
        } else {
            eventContinuation.finish()
        }
    }

    private func eventsChannelReaderDidEnd(_ readerID: UInt64) {
        if eventsChannelState == .streaming(readerID: readerID) {
            eventsChannelState = .idle
        } else {
            // Ended mid-open: the subscribe path reconciles (and cleans up
            // this marker on its failure path).
            endedEventsReaders.insert(readerID)
        }
    }

    // MARK: Terminal channel
    //
    // One dedicated interactive terminal channel is exempt from the exec-slot
    // queue. The session budget is 8 RPC slots + events + terminal = sshd's
    // default MaxSessions 10.

    private enum TerminalChannelState: Equatable {
        case idle
        case streaming(readerID: UInt64)
    }

    private var terminalChannelState: TerminalChannelState = .idle
    private var nextTerminalReaderID: UInt64 = 0

    // MARK: Attach
    //
    // Citadel 0.12.1's public API has no PTY + exec-request combination —
    // `withPTY` sends a PTY request followed by a *shell* request — so the
    // attach command rides in as the shell's first input line, `exec`'d to
    // replace the shell outright: when attach exits, nothing is left on the
    // channel and it closes. Closing a PTY channel HUPs the remote process
    // group, which ends attach promptly (verified against localhost sshd in
    // the #11 e2e).

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        let socketPath = try await resolvedSocketPath()
        guard terminalChannelState == .idle else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        let bootstrapLine = try Self.attachBootstrapLine(
            attachCommand: attachCommand, request: request, socketPath: socketPath)
        // Deliberately unbounded (#22): raw PTY bytes have no framing, no
        // seq, and no snapshot to resync from, so a shed chunk would corrupt
        // the escape stream for the rest of the session. Volume is
        // interactive TUI output bounded by SSH channel flow control, and
        // the consumer is a synchronous terminal feed.
        let (output, outputContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        // Reliable keystrokes and resizes remain ordered. Touch-scroll rows
        // are lossy viewport intent, so the queue coalesces and bounds them
        // instead of letting momentum block later typing on a slow link.
        let input = TerminalAttachInputQueue()
        nextTerminalReaderID += 1
        let readerID = nextTerminalReaderID
        let readerTask = Task {
            await self.runAttachChannel(
                readerID: readerID, request: request, bootstrapLine: bootstrapLine,
                input: input, output: outputContinuation)
        }
        // No suspension between the idle guard and here (attachBootstrapLine
        // is synchronous), so the reader cannot have observed — let alone
        // ended — a state it is only now being recorded into.
        terminalChannelState = .streaming(readerID: readerID)
        return TerminalAttachSession(output: output, input: input) {
            input.finish()
            readerTask.cancel()
            await readerTask.value
        }
    }

    /// The line typed into the attach channel's login shell to become the
    /// attach process (see the MARK above for why a shell is involved at
    /// all). `exec` replaces the shell so the attach process's exit is the
    /// channel's end. The line must parse identically in POSIX shells and
    /// fish — both treat single-quoted text literally as long as it contains
    /// no quote, backslash, or control characters, so targets are restricted
    /// to exactly that (a Pane id that violates it could only come from a
    /// hostile server, and refusing beats handing it a shell).
    ///
    /// The attach process runs under `/bin/sh` so `HERDR_SOCKET_PATH` can pin
    /// the herdr CLI to this Host's configured socket (fish parses prefix
    /// assignments differently, so the login shell cannot set it portably);
    /// without it the CLI resolves the default session and a named-session
    /// target is "not found" there.
    static func attachBootstrapLine(
        attachCommand: String, request: TerminalAttachRequest, socketPath: String
    ) throws -> String {
        let unquotable: (Character) -> Bool = { character in
            character == "'" || character == "\\"
                || character.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
        guard !request.target.isEmpty, !request.target.contains(where: unquotable) else {
            throw TransportError.channelFailed(
                detail: "attach target cannot be quoted for the remote shell")
        }
        guard let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            throw TransportError.channelFailed(
                detail: "The remote socket path cannot be quoted safely.")
        }
        let takeover = request.takeover ? " --takeover" : ""
        // The marker goes out last thing before the exec, so everything the
        // login shell said on its own way here can be dropped. See
        // AttachBootstrapHandshake.
        return "exec /bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
            + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
            + "exec \(attachCommand) \"$1\"\(takeover)' attach "
            + "'\(request.target)' \(quotedSocketPath)\n"
    }

    /// The attach channel's lifetime: opens the PTY, types the bootstrap
    /// line, then pumps bytes both ways until the channel ends. Ending is by
    /// explicit close or the remote attach exiting: cancelling the reader
    /// task only ends the *local* inbound stream, the PTY body then returns,
    /// and Citadel closes the channel on the way out. Takes no exec slot
    /// (see MARK).
    private func runAttachChannel(
        readerID: UInt64,
        request: TerminalAttachRequest,
        bootstrapLine: String,
        input: TerminalAttachInputQueue,
        output continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) async {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: request.cols,
            terminalRowHeight: request.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        /// nil means the stream ends gracefully: explicit `end()`, or the
        /// remote attach exiting cleanly (the user detached inside the TUI).
        var failure: TransportError?
        /// The read loop draining to a clean end (exit status 0). The remote
        /// exiting closes the channel before `withPTY` gets to close it on
        /// the way out, and that close's "already closed" error must not
        /// repaint a clean detach as a failure (found by the #11 e2e).
        var sawCleanEnd = false
        /// Citadel closes the channel after this closure returns. If that
        /// cleanup also fails, preserve the pump failure that ended the live
        /// session instead of replacing it with a secondary close error.
        var pumpFailure: TerminalAttachPumpError?
        do {
            try await client.withPTY(pty) { inbound, outbound in
                try await outbound.write(ByteBuffer(string: bootstrapLine))
                do {
                    sawCleanEnd = try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            do {
                                try await Self.writeTerminalAttachInput(
                                    input,
                                    write: { data in
                                        try await outbound.write(ByteBuffer(bytes: data))
                                    },
                                    resize: { cols, rows in
                                        try await outbound.changeSize(
                                            cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                                    })
                                return false
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                throw TerminalAttachPumpError.input(String(describing: error))
                            }
                        }
                        group.addTask {
                            // The login shell's banner, prompt, and echo of the
                            // bootstrap line stay off the terminal; the gate
                            // opens on the bootstrap's own marker.
                            var gate = AttachBootstrapGate()
                            func yield(_ bytes: Data) {
                                guard !bytes.isEmpty else { return }
                                continuation.yield(bytes)
                            }
                            do {
                                for try await chunk in inbound {
                                    switch chunk {
                                    case .stdout(let buffer), .stderr(let buffer):
                                        // A PTY merges everything into one byte stream;
                                        // stderr chunks should not occur, but any that do
                                        // belong on the terminal too.
                                        yield(gate.admit(Data(buffer.readableBytesView)))
                                    }
                                }
                                // Ended before the handshake: the withheld noise
                                // is the only account of why.
                                yield(gate.flush())
                                return true
                            } catch is CancellationError {
                                // The user left. Nothing withheld is worth
                                // painting on the way out.
                                throw CancellationError()
                            } catch {
                                yield(gate.flush())
                                throw TerminalAttachPumpError.output(String(describing: error))
                            }
                        }
                        defer {
                            input.finish()
                            group.cancelAll()
                        }
                        return try await group.next() ?? true
                    }
                } catch let error as TerminalAttachPumpError {
                    pumpFailure = error
                    throw error
                }
            }
            failure = nil
        } catch is CancellationError {
            failure = nil
        } catch {
            if Task.isCancelled || sawCleanEnd {
                failure = nil  // Explicit end() or a clean remote exit.
            } else {
                switch pumpFailure {
                case .input(let detail):
                    failure = TransportError.channelFailed(detail: "attach input: \(detail)")
                case .output(let detail):
                    failure = TransportError.channelFailed(detail: "attach channel: \(detail)")
                case nil:
                    failure = TransportError.channelFailed(detail: "attach channel: \(error)")
                }
            }
        }
        // Remote exit must also wake a writer suspended on the input queue.
        input.finish()
        // State first, continuation second: a consumer resuming on the
        // stream's end must already see the channel as free.
        if terminalChannelState == .streaming(readerID: readerID) {
            terminalChannelState = .idle
        }
        if let failure {
            continuation.finish(throwing: failure)
        } else {
            continuation.finish()
        }
    }

    static func writeTerminalAttachInput(
        _ input: TerminalAttachInputQueue,
        write: (Data) async throws -> Void,
        resize: (Int, Int) async throws -> Void
    ) async throws {
        while let item = await input.next() {
            guard !Task.isCancelled else { return }
            switch item {
            case .keystrokes(let data):
                try await write(data)
            case .scroll(let data):
                try await write(data)
                try await Task.sleep(for: TerminalAttachInputQueue.scrollPacingInterval)
            case .resize(let cols, let rows):
                try await resize(cols, rows)
            }
        }
    }

    /// Removes and returns the first complete line (newline stripped) from
    /// `buffer`, or nil if no full line has arrived yet.
    private static func takeLine(from buffer: inout Data) -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer = Data(buffer[buffer.index(after: newline)...])
        return line
    }

    /// Whether the SSH connection is still alive (Citadel tracks the
    /// underlying channel's liveness). False after `close()` or a remote
    /// death; this transport is then dead for good — Citadel's auto-reconnect
    /// is deliberately off (`.never`), re-establishing is the reconnect
    /// machinery's job (#18) so backoff stays bounded and observable.
    var isConnected: Bool {
        client.isConnected
    }

    /// The first hop's liveness when this Transport uses a Jump Host.
    /// Internal so the real-SSH lifecycle test can verify both Citadel clients
    /// are torn down; direct connections return nil.
    var jumpHostIsConnected: Bool? {
        jumpClient?.isConnected
    }

    /// Closes the SSH connection. Explicit close is the only way to end
    /// Citadel channels — a live exec channel ignores task cancellation.
    func close() async throws {
        let stagingClients = Array(imageStageClients.values)
        imageStageClients.removeAll()
        for sftp in stagingClients {
            try? await sftp.close()
        }
        do {
            try await client.close()
        } catch {
            if let jumpClient {
                try? await jumpClient.close()
            }
            throw error
        }
        if let jumpClient {
            try await jumpClient.close()
        }
    }

    /// Executes one parameterless request with cold-start recovery.
    private func request<R: Decodable>(method: String, decoding type: R.Type) async throws -> R {
        try await request(method: method, params: HerdrWire.EmptyParams(), decoding: type)
    }

    /// Executes one request with cold-start recovery.
    private func request<P: Encodable, R: Decodable>(
        method: String, params: P, decoding type: R.Type
    ) async throws -> R {
        try await withColdStartWake {
            try await self.performRequest(method: method, params: params, decoding: type)
        }
    }

    /// Runs `operation` with cold-start recovery (#6): connection refused
    /// means the socket exists but the server is stopped, so run the wake
    /// command and retry. Strictly bounded — one wake, one retry — so a wake
    /// that does not help surfaces `.serverNotRunning` to the user instead
    /// of looping silently.
    private func withColdStartWake<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch TransportError.serverNotRunning(let path) {
            do {
                try await wakeServer(socketPath: path)
            } catch TransportError.cancelled {
                throw TransportError.cancelled
            } catch TransportError.timedOut {
                throw TransportError.timedOut
            } catch {
                // The wake itself failed (herdr missing, command errored):
                // the actionable problem is still a server that is not
                // running on this Host.
                throw TransportError.serverNotRunning(path: path)
            }
            return try await operation()
        }
    }

    /// Wakes the herdr server via the Host's wake command; concurrent
    /// refused requests share one in-flight wake. A hung wake may keep
    /// running remotely after its local SSH channel is abandoned, so waiters
    /// return `.timedOut` and invalidate the Transport instead of waiting for
    /// that remote process to exit.
    private func wakeServer(socketPath: String) async throws {
        try await withRequestDeadline(requestTimeout) {
            try await self.wake.value {
                try await self.runWakeCommand(socketPath: socketPath)
            }
        }
    }

    /// Runs the wake command over a slot-gated no-PTY exec channel with
    /// stdin at EOF from the start (`< /dev/null`). `HERDR_SOCKET_PATH` pins
    /// the bridge and the server it spawns to this Host's configured socket;
    /// named locations also set `HERDR_SESSION` so the spawned server uses
    /// that session's state directory instead of the default session's state.
    /// The path rides as a positional argument so only the outer shell ever
    /// quotes it. The bridge's entry point ensures the server is running
    /// (spawn + wait for socket) before it starts bridging; the bridge then
    /// reads EOF and exits — so the command completing implies a live socket,
    /// and its own lifetime bounds the channel without writing or closing
    /// anything mid-flight.
    private func runWakeCommand(socketPath: String) async throws {
        let command = try Self.wakeExecCommand(
            wakeCommand: wakeCommand, socketPath: socketPath, socketLocation: socketLocation)
        try await execChannelBudget.withChannel {
            _ = try await self.client.executeCommand(command)
        }
    }

    /// The full remote command for waking this Host's configured herdr
    /// server. It runs under POSIX sh because login shells such as fish do
    /// not share assignment syntax, and passes the socket and optional named
    /// session as arguments so the wrapper script never interpolates their
    /// bytes.
    static func wakeExecCommand(
        wakeCommand: String, socketPath: String, socketLocation: HerdrSocketLocation
    ) throws -> String {
        guard let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            throw TransportError.channelFailed(
                detail: "The remote socket path cannot be quoted safely.")
        }
        let command: String
        switch socketLocation {
        case .namedSession(let sessionName):
            guard HerdrSessionName.isValid(sessionName) else {
                throw TransportError.channelFailed(
                    detail: "The herdr session name is invalid.")
            }
            command = "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$1\"; "
                + "export HERDR_SESSION=\"$2\"; \(wakeCommand) < /dev/null' wake "
                + "\(quotedSocketPath) \(sessionName)"
        case .defaultSession, .absolutePath:
            command = "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$1\"; "
                + "\(wakeCommand) < /dev/null' wake \(quotedSocketPath)"
        }
        return cLocaleCommand(command)
    }

    /// One no-PTY exec channel per request, raced against the per-request
    /// deadline. The channel is ended by returning from the `withExec` body
    /// as soon as a full response line has arrived (Citadel closes the
    /// channel on return) — never by task cancellation, which a live exec
    /// channel does not respond to.
    private func performRequest<P: Encodable, R: Decodable>(
        method: String, params: P, decoding type: R.Type
    ) async throws -> R {
        let requestID = UUID().uuidString
        let line = try HerdrWire.requestLine(id: requestID, method: method, params: params)
        let responseLine = try await withRequestDeadline(requestTimeout) {
            let (socketPath, socatPath) = try await self.resolvedExchangePaths()
            return try await self.performExchange(
                line: line, socketPath: socketPath, socatPath: socatPath, method: method)
        }
        return try HerdrWire.decodeResult(type, fromResponseLine: responseLine, requestID: requestID)
    }

    /// Takes a channel slot, runs one exec+socat exchange, and returns the
    /// raw response bytes (guaranteed to contain a full line).
    private func performExchange(
        line: String, socketPath: String, socatPath: String, method: String
    ) async throws -> Data {
        try await execChannelBudget.withChannel {
            var stdout = Data()
            var stderr = Data()
            do {
                let command = try Self.socatCommand(
                    socatPath: socatPath, socketPath: socketPath)
                try await self.client.withExec(command) {
                    inbound, outbound in
                    // A fast-failing command (socket absent, server stopped) can
                    // close the channel before this write lands; the read loop
                    // below still drains stderr and surfaces the real failure.
                    try? await outbound.write(ByteBuffer(string: line))
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer):
                            stdout.append(contentsOf: buffer.readableBytesView)
                            if stdout.contains(0x0A) { return }
                        case .stderr(let buffer):
                            stderr.append(contentsOf: buffer.readableBytesView)
                        }
                    }
                }
            } catch is CancellationError {
                throw TransportError.cancelled
            } catch {
                throw await self.classifyExecFailure(stderr: stderr, socketPath: socketPath)
                    ?? TransportError.channelFailed(
                        detail: "\(method): \(error); stderr: \(Self.preview(stderr))")
            }
            // A cancelled exchange ends its read through the local inbound
            // stream, after which withExec has already closed the channel;
            // surface that instead of misreading the truncated output as a
            // protocol error.
            try Task.checkCancellation()
            if !stdout.contains(0x0A),
                let failure = await self.classifyExecFailure(
                    stderr: stderr, socketPath: socketPath)
            {
                throw failure
            }
            return stdout
        }
    }

    /// Bounds a request without structurally waiting for the losing task.
    /// SwiftNIO futures do not honor Swift task cancellation, so a task-group
    /// race can remain stuck after its timer wins. Expiry or caller
    /// cancellation invalidates the whole Transport independently, which
    /// closes the channel and lets any abandoned bridge unwind later.
    private func withRequestDeadline<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await AsyncDeadline.run(
                for: timeout,
                onTimeout: { await self.invalidateAfterAbandonedRequest() },
                onCancel: { await self.invalidateAfterAbandonedRequest() },
                operation: operation)
        } catch AsyncDeadlineError.timedOut {
            throw TransportError.timedOut
        } catch is CancellationError {
            throw TransportError.cancelled
        }
    }

    private func invalidateAfterAbandonedRequest() async {
        try? await close()
    }

    /// The socket and socat paths an exchange needs, resolved concurrently:
    /// on a cold connection each is its own remote probe, and neither
    /// depends on the other, so paying them sequentially would double the
    /// first request's setup latency. The await order keeps failure
    /// priority: a Host whose home directory cannot be read fails at the
    /// remote-environment check rather than at socat.
    private func resolvedExchangePaths() async throws -> (socketPath: String, socatPath: String) {
        async let socketPath = resolvedSocketPath()
        async let socatPath = resolvedSocatPath()
        return (try await socketPath, try await socatPath)
    }

    /// The absolute socket path on this Host, resolving the remote home
    /// directory for home-relative locations.
    private func resolvedSocketPath() async throws -> String {
        if case .absolutePath(let path) = socketLocation { return path }
        return socketLocation.path(homeDirectory: try await remoteHomeDirectory())
    }

    /// The shared home resolution, with the wait — not the resolution —
    /// deadline-bounded, exactly like `wakeServer()`.
    private func remoteHomeDirectory() async throws -> String {
        try await withRequestDeadline(requestTimeout) {
            try await self.homeDirectory.value {
                try await self.resolveHomeDirectoryOverExec()
            }
        }
    }

    private func resolveHomeDirectoryOverExec() async throws -> String {
        try await execChannelBudget.withChannel {
            let output: ByteBuffer
            do {
                output = try await self.client.executeCommand(
                    Self.cLocaleCommand(self.homeCommand))
            } catch {
                throw TransportError.homeDirectoryUnresolvable(detail: String(describing: error))
            }
            return try Self.parseRemoteHome(output)
        }
    }

    /// The absolute socat path on this Host, discovered once per connection.
    private func resolvedSocatPath() async throws -> String {
        try await withRequestDeadline(requestTimeout) {
            try await self.socatExecutable.value {
                try await self.resolveSocatPathOverExec()
            }
        }
    }

    private func resolveSocatPathOverExec() async throws -> String {
        try await execChannelBudget.withChannel {
            let output: ByteBuffer
            do {
                output = try await self.client.executeCommand(
                    Self.socatProbeCommand(
                        preferredPath: self.preferredSocatPath,
                        discovery: self.socatDiscovery))
            } catch is CancellationError {
                throw TransportError.cancelled
            } catch {
                throw TransportError.channelFailed(
                    detail: "socat discovery: \(String(describing: error))")
            }
            guard
                let path = Self.markerValue(
                    in: Data(output.readableBytesView), prefix: Self.socatOutputPrefix),
                RemoteShellPath.isQuotableAbsolute(path)
            else {
                throw TransportError.socatMissing(path: self.preferredSocatPath)
            }
            return path
        }
    }

    /// Maps the observable failure shapes (verified against herdr 0.7.4 in
    /// the #3 spike) onto taxonomy cases:
    /// - missing socket:  socat stderr `E connect(... "<sock>" ...): No such file or directory`
    /// - stale socket:    socat stderr `E connect(... "<sock>" ...): Connection refused`
    ///
    /// socat connect diagnostics are keyed on their `E connect` marker plus
    /// the quoted socket path: shells like fish echo the whole failing
    /// command line (which contains both paths), so path presence alone
    /// cannot distinguish the shapes.
    ///
    /// socat's own absence is deliberately not classified here. Discovery
    /// already proved the executable exists before any exchange ran, and the
    /// alternative — matching the socat path against arbitrary login-shell
    /// error text — reports every *other* reason an existing socat fails to
    /// exec (no execute permission, a missing shared library, a noexec mount)
    /// as "socat is not installed", sending the user to fix the one thing that
    /// is already correct.
    private func classifyExecFailure(stderr: Data, socketPath: String) -> TransportError? {
        let text = String(decoding: stderr, as: UTF8.self)
        if text.contains("E connect"), text.contains("\"\(socketPath)\"") {
            if text.contains("No such file or directory") {
                return .socketNotFound(path: socketPath)
            }
            if text.contains("Connection refused") {
                return .serverNotRunning(path: socketPath)
            }
        }
        return nil
    }

    private static func preview(_ stderr: Data) -> String {
        String(decoding: stderr.prefix(200), as: UTF8.self)
    }

    private static let homeOutputPrefix = "__HEELER_HOME__="
    private static let socatOutputPrefix = "__HEELER_SOCAT__="
    private static let stageDirectoryOutputPrefix = "__HEELER_STAGE_DIR__="
    private static let pluginConfigDirOutputPrefix = "__HEELER_PLUGIN_CONFIG_DIR__="

    /// The value of the last marker-prefixed line in an exec command's
    /// output. Markers keep login-shell stdout noise harmless; the last
    /// occurrence wins so a shell echoing the command line cannot spoof an
    /// earlier one.
    private static func markerValue(in output: Data, prefix: String) -> String? {
        String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .first { $0.hasPrefix(prefix) }
            .map { line in
                var value = String(line.dropFirst(prefix.count))
                if value.last == "\r" { value.removeLast() }
                return value
            }
    }

    private static func parseRemoteHome(_ output: ByteBuffer) throws -> String {
        let home = markerValue(in: Data(output.readableBytesView), prefix: homeOutputPrefix)
        guard let home, RemoteShellPath.isQuotableAbsolute(home) else {
            throw TransportError.homeDirectoryUnresolvable(
                detail: "home command printed: \(String(buffer: output).prefix(200))")
        }
        return home
    }

    private static func parseStageDirectory(_ output: ByteBuffer) throws -> String {
        let directory = markerValue(
            in: Data(output.readableBytesView), prefix: stageDirectoryOutputPrefix)
        guard let directory else {
            throw ImageStagingError.remoteTemporaryDirectoryFailed
        }
        return try StagedImage(path: "\(directory)/placeholder").fileURL
            .deletingLastPathComponent().path
    }

    /// Prints the marker-delimited absolute socat path: the preferred path if
    /// it is executable, otherwise whatever the Host's PATH resolves `socat`
    /// to. Runs under POSIX sh because login shells do not share substitution
    /// syntax, and passes both inputs as positional arguments so neither is
    /// interpolated into the script body.
    ///
    /// Always exits 0. Absence is reported by the marker's absence, never by a
    /// status code, so "no socat here" stays a classified `socatMissing`
    /// instead of an opaque channel failure. A preferred path that cannot be
    /// quoted safely is passed as the empty string, which `[ -x ]` rejects —
    /// discovery then falls through to PATH exactly as it does for a path that
    /// simply is not there.
    ///
    /// Not private: CI provisions no sshd, so the e2e coverage of discovery all
    /// skips there and this command's shape is pinned by direct unit tests.
    static func socatProbeCommand(
        preferredPath: String, discovery: SocatDiscovery
    ) -> String {
        let quotedPreferredPath = RemoteShellPath.quotedAbsolute(preferredPath) ?? "''"
        let searchesPath = discovery == .automatic ? "1" : "0"
        let script =
            "preferred=\"$1\"; searches_path=\"$2\"; "
            + "if [ -x \"$preferred\" ]; then "
            + "printf \"\(socatOutputPrefix)%s\\n\" \"$preferred\"; exit 0; fi; "
            + "[ \"$searches_path\" = 1 ] || exit 0; "
            + "found=$(command -v socat 2>/dev/null) || exit 0; "
            + "case \"$found\" in /*) [ -x \"$found\" ] && "
            + "printf \"\(socatOutputPrefix)%s\\n\" \"$found\";; esac; exit 0"
        return cLocaleCommand(
            "/bin/sh -c '\(script)' herdr-socat-probe \(quotedPreferredPath) \(searchesPath)")
    }

    private static func socatCommand(socatPath: String, socketPath: String) throws -> String {
        guard
            let quotedSocatPath = RemoteShellPath.quotedAbsolute(socatPath),
            let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath)
        else {
            throw TransportError.channelFailed(
                detail: "The remote socat or socket path cannot be quoted safely.")
        }
        return cLocaleCommand("\(quotedSocatPath) - UNIX-CONNECT:\(quotedSocketPath)")
    }

    /// Stabilizes every parsed remote exec surface. Error classification and
    /// JSON diagnostics must not change with the Host account's locale.
    private static func cLocaleCommand(_ command: String) -> String {
        "LC_ALL=C \(command)"
    }
}

extension SSHCredentials {
    /// The Citadel authentication method for these credentials. Lives here so
    /// the credentials type itself stays free of SSH library types.
    fileprivate func citadelMethod(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .ed25519(let privateKey):
            .ed25519(username: username, privateKey: privateKey)
        case .password(let password):
            .passwordBased(username: username, password: password)
        }
    }
}
