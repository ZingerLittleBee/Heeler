package dev.bybee.heeler.core.transport

import android.util.Base64
import dev.bybee.heeler.core.notifications.NotificationRegistrationError
import dev.bybee.heeler.core.ssh.PtyRequest
import dev.bybee.heeler.core.ssh.SshAuthentication
import dev.bybee.heeler.core.ssh.SshConnection
import dev.bybee.heeler.core.ssh.SshDataChannel
import dev.bybee.heeler.core.ssh.SshException
import dev.bybee.heeler.core.ssh.SshExecChannel
import dev.bybee.heeler.core.ssh.SshHostKey
import dev.bybee.heeler.core.ssh.SshSftpFile
import dev.bybee.heeler.core.ssh.SshSftpSession
import dev.bybee.heeler.core.wire.AgentInfoResponse
import dev.bybee.heeler.core.wire.AgentListResponse
import dev.bybee.heeler.core.wire.AgentPromptParams
import dev.bybee.heeler.core.wire.AgentPromptedResponse
import dev.bybee.heeler.core.wire.AgentReadParams
import dev.bybee.heeler.core.wire.AgentRenameParams
import dev.bybee.heeler.core.wire.AgentSendKeysParams
import dev.bybee.heeler.core.wire.AgentStartParams
import dev.bybee.heeler.core.wire.AgentStartedResponse
import dev.bybee.heeler.core.wire.OkResponse
import dev.bybee.heeler.core.wire.PaneReadParams
import dev.bybee.heeler.core.wire.PaneReadResponse
import dev.bybee.heeler.core.wire.PaneTarget
import dev.bybee.heeler.core.wire.PongResponse
import dev.bybee.heeler.core.wire.SessionSnapshot
import dev.bybee.heeler.core.wire.SessionSnapshotResponse
import dev.bybee.heeler.core.wire.SubscriptionStartedResponse
import dev.bybee.heeler.core.wire.TabCreateParams
import dev.bybee.heeler.core.wire.TabCreatedResponse
import dev.bybee.heeler.core.wire.WorkspaceInfoResponse
import dev.bybee.heeler.core.wire.WorkspaceRenameParams
import dev.bybee.heeler.core.wire.WorktreeCreateParams
import dev.bybee.heeler.core.wire.WorktreeCreatedResponse
import dev.bybee.heeler.core.wire.WorktreeRemoveParams
import dev.bybee.heeler.core.wire.WorktreeRemovedResponse
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

/** The response shape of `herdr session list --json`. */
@Serializable
private data class SessionListResponse(val sessions: List<HerdrSession>)

/**
 * The libssh2-backed Transport. Ordinary herdr RPCs use fresh direct-streamlocal
 * channels, Events owns one reserved forwarding channel, and Attach owns one
 * reserved PTY exec channel per Host (ADR 0011).
 */
class HeelerSshTransport private constructor(
    private val connection: SshConnection,
    private val settings: SshTransportSettings,
) : Transport {
    companion object {
        /** Lowest herdr protocol this build can drive; lower Hosts are refused. */
        const val MINIMUM_PROTOCOL_VERSION = 17

        /**
         * Highest protocol in the committed schema. This is advisory only: the
         * protocol check is a floor, never equality. Additive protocol 19 must
         * remain usable rather than repeating the outage caused by equality.
         */
        const val GENERATED_PROTOCOL_VERSION = 19
        const val MAXIMUM_RESPONSE_BYTES = 1_048_576
        private const val SFTP_OPEN_WRITE_CREATE_TRUNCATE = 0x2 or 0x8 or 0x10
        private const val MODE_PRIVATE_FILE = 0x180 // 0600
        private const val MODE_PRIVATE_DIRECTORY = 0x1c0 // 0700
        private const val HOME_OUTPUT_PREFIX = "__HEELER_HOME__="
        private const val STAGE_DIRECTORY_OUTPUT_PREFIX = "__HEELER_STAGE_DIR__="
        private const val PLUGIN_CONFIG_DIRECTORY_OUTPUT_PREFIX = "__HEELER_PLUGIN_CONFIG_DIR__="
        private const val NOTIFICATION_FILE_MARKER = "__HEELER_NOTIFICATION_FILE__"
        private const val NOTIFICATION_REGISTRATION_FILE_NAME = "notifications.json"
        private const val NOTIFICATION_CONFIG_FILE_NAME = "notify.json"
        private val shellReadinessBudget = 10_000.milliseconds
        private val shellReadinessRetryDelay = 500.milliseconds

        /** Establishes a direct or jump-host SSH Transport with TOFU verification. */
        suspend fun connect(settings: SshTransportSettings): HeelerSshTransport {
            val timeoutMs = settings.requestTimeout.inWholeMilliseconds
                .coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
            val connection = try {
                val jump = settings.jump
                if (jump == null) {
                    connectAndAuthenticate(
                        host = settings.host,
                        port = settings.port,
                        username = settings.username,
                        credentials = settings.credentials,
                        policy = settings.hostKeyPolicy,
                        timeoutMs = timeoutMs,
                    )
                } else {
                    val jumpConnection = try {
                        connectAndAuthenticate(
                            host = jump.host,
                            port = jump.port,
                            username = jump.username,
                            credentials = jump.credentials,
                            policy = settings.hostKeyPolicy,
                            timeoutMs = timeoutMs,
                        )
                    } catch (failure: Throwable) {
                        throw TransportError.JumpHostFailed(mapConnectFailure(failure))
                    }
                    val target = try {
                        SshConnection.connectViaJump(
                            jump = jumpConnection,
                            targetHost = settings.host,
                            targetPort = settings.port,
                            timeoutMs = timeoutMs,
                        ) { key ->
                            verifyHostKey(settings.host, settings.port, settings.hostKeyPolicy, key)
                        }
                    } catch (failure: Throwable) {
                        throw if (failure is TransportError) failure else mapConnectFailure(failure)
                    }
                    try {
                        target.authenticate(settings.username, settings.credentials.toNative())
                        target
                    } catch (failure: Throwable) {
                        try {
                            target.disconnect()
                        } catch (_: Throwable) {
                            // Preserve the authentication failure.
                        }
                        throw if (failure is TransportError) failure else TransportError.AuthenticationFailed
                    }
                }
            } catch (failure: Throwable) {
                throw if (failure is TransportError) failure else mapConnectFailure(failure)
            }
            return HeelerSshTransport(connection, settings)
        }

        private suspend fun connectAndAuthenticate(
            host: String,
            port: Int,
            username: String,
            credentials: SshCredentials,
            policy: HostKeyPolicy,
            timeoutMs: Int,
        ): SshConnection {
            val connection = SshConnection.connect(host, port, timeoutMs) { key ->
                verifyHostKey(host, port, policy, key)
            }
            try {
                connection.authenticate(username, credentials.toNative())
                return connection
            } catch (failure: Throwable) {
                try {
                    connection.disconnect()
                } catch (_: Throwable) {
                    // The original authentication outcome remains authoritative.
                }
                throw if (failure is TransportError) failure else TransportError.AuthenticationFailed
            }
        }

        private suspend fun verifyHostKey(
            host: String,
            port: Int,
            policy: HostKeyPolicy,
            hostKey: SshHostKey,
        ): Boolean {
            val parsed = HostKeyFingerprint.fromPublicKeyBlob(hostKey.rawKey)
            val presented = HostKeyFingerprint.fromDigest(parsed.digest, hostKey.algorithm)
            val known = policy.knownHosts.fingerprint(host, port, hostKey.algorithm)
            if (known != null) {
                if (known != presented) throw TransportError.HostKeyMismatch(known, presented)
                return true
            }
            val candidate = HostKeyCandidate(host, port, presented)
            if (!policy.confirmFirstConnect(candidate)) throw TransportError.HostKeyRejected(presented)
            policy.knownHosts.setFingerprint(presented, host, port)
            return true
        }

        private fun mapConnectFailure(failure: Throwable): TransportError = when (failure) {
            is TransportError -> failure
            is SshException.TimedOut -> TransportError.TimedOut
            is SshException.HostKeyRejected -> TransportError.AuthenticationFailed
            is SshException.Closed -> TransportError.SshUnreachable(failure.message.orEmpty())
            is SshException.NativeFailure, is SshException.Protocol ->
                TransportError.SshUnreachable(failure.message.orEmpty())
            else -> TransportError.SshUnreachable(failure.toString())
        }
    }

    private val admission = SshChannelAdmission()
    private val stateMutex = Mutex()
    private val homeMutex = Mutex()
    private val notificationDirectoryMutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var connected = true
    private var eventsOpen = false
    private var terminalOpen = false
    private var cachedHomeDirectory: String? = null
    private var cachedNotificationDirectory: String? = null

    /** Server identity from `ping`, enforcing a protocol floor rather than equality. */
    override suspend fun ping(): ServerInfo {
        val pong = request("ping", HerdrWire.EmptyParams, HerdrWire.EmptyParams.serializer(), PongResponse.serializer())
        if (pong.protocolVersion < MINIMUM_PROTOCOL_VERSION) {
            throw TransportError.ProtocolVersionMismatch(pong.protocolVersion, MINIMUM_PROTOCOL_VERSION)
        }
        return ServerInfo(
            version = pong.version,
            protocolVersion = pong.protocolVersion,
            exceedsGeneratedProtocol = pong.protocolVersion > GENERATED_PROTOCOL_VERSION,
        )
    }

    override suspend fun listSessions(): List<HerdrSession> {
        val response = runHostCommand(settings.sessionListCommand)
        val sessions = try {
            HerdrWire.json.decodeFromString(SessionListResponse.serializer(), response.decodeToString()).sessions
        } catch (_: Throwable) {
            throw TransportError.MalformedResponse("herdr session list returned invalid JSON: ${response.preview()}")
        }
        if (sessions.any { !HerdrSessionName.isValid(it.name) }) {
            throw TransportError.MalformedResponse("herdr session list returned an invalid session name")
        }
        return sessions
    }

    override suspend fun availableAgentKinds(): List<SupportedAgentKind> {
        val discovered = runHostCommand(settings.agentDiscoveryCommand)
            .decodeToString()
            .lineSequence()
            .mapNotNull { line ->
                line.takeIf { it.startsWith(SshTransportSettings.AGENT_AVAILABILITY_MARKER) }
                    ?.removePrefix(SshTransportSettings.AGENT_AVAILABILITY_MARKER)
                    ?.let(SupportedAgentKind::fromRawValue)
            }.toSet()
        return SupportedAgentKind.entries.filter(discovered::contains)
    }

    override suspend fun listSkills(query: SkillListQuery): List<AgentSkill> {
        val sources = SkillSourceCatalog.sources(query.kind)
        if (sources.isEmpty()) return emptyList()
        val home = remoteHomeDirectory()
        val resolved = sources.mapNotNull { source ->
            val root = when (source.root) {
                SkillSource.Root.HOME -> home
                SkillSource.Root.PROJECT -> query.projectRoot
            }?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
            val directory = root.removeSuffix("/") + "/" + source.relativePath
            val quoted = RemoteShellPath.quotedAbsolute(directory) ?: return@mapNotNull null
            SkillProbe.ResolvedSource(source.scope, quoted, source.layout, source.commandPrefix)
        }
        if (resolved.isEmpty()) return emptyList()
        return SkillProbe.skills(runHostCommand(SkillProbe.command(resolved)), resolved)
    }

    override suspend fun readSkillFile(path: String): String {
        val quoted = RemoteShellPath.quotedAbsolute(path)
            ?: throw TransportError.ChannelFailed("skill path is not quotable")
        return SkillProbe.documentContent(runHostCommand(SkillProbe.readFileCommand(quoted)))
            ?: throw TransportError.MalformedResponse("The skill file is gone or unreadable on the Host.")
    }

    override suspend fun listAgents(): List<Agent> =
        request("agent.list", HerdrWire.EmptyParams, HerdrWire.EmptyParams.serializer(), AgentListResponse.serializer())
            .agents.map(Agent::fromWire)

    override suspend fun sessionSnapshot(): SessionSnapshot =
        request(
            "session.snapshot",
            HerdrWire.EmptyParams,
            HerdrWire.EmptyParams.serializer(),
            SessionSnapshotResponse.serializer(),
        ).snapshot

    override suspend fun readPane(params: PaneReadParams) =
        request("pane.read", params, PaneReadParams.serializer(), PaneReadResponse.serializer()).read

    override suspend fun readAgent(params: AgentReadParams) =
        request("agent.read", params, AgentReadParams.serializer(), PaneReadResponse.serializer()).read

    override suspend fun promptAgent(params: AgentPromptParams): Agent =
        Agent.fromWire(
            request("agent.prompt", params, AgentPromptParams.serializer(), AgentPromptedResponse.serializer()).agent,
        )

    override suspend fun sendAgentKeys(params: AgentSendKeysParams) {
        request("agent.send_keys", params, AgentSendKeysParams.serializer(), OkResponse.serializer())
    }

    override suspend fun startAgent(request: AgentLaunchRequest): Agent {
        val created = request(
            "tab.create",
            TabCreateParams(cwd = request.cwd, focus = false, workspaceID = request.workspaceID),
            TabCreateParams.serializer(),
            TabCreatedResponse.serializer(),
        )
        return try {
            Agent.fromWire(startAgentAwaitingShell(request, created.rootPane.paneID).agent)
        } catch (failure: HerdrApiError) {
            try {
                closePane(PaneTarget(created.rootPane.paneID))
            } catch (_: Throwable) {
                // Preserve the primary `agent.start` rejection.
            }
            throw failure
        }
    }

    override suspend fun startAgentInNewWorktree(request: AgentLaunchRequest, worktree: WorktreeSpec): Agent {
        val created = request(
            "worktree.create",
            WorktreeCreateParams(base = worktree.base, branch = worktree.branch, focus = false, workspaceID = request.workspaceID),
            WorktreeCreateParams.serializer(),
            WorktreeCreatedResponse.serializer(),
        )
        return try {
            Agent.fromWire(startAgentAwaitingShell(request, created.rootPane.paneID).agent)
        } catch (failure: HerdrApiError) {
            try {
                request(
                    "worktree.remove",
                    WorktreeRemoveParams(workspaceID = created.workspace.workspaceID),
                    WorktreeRemoveParams.serializer(),
                    WorktreeRemovedResponse.serializer(),
                )
            } catch (_: Throwable) {
                // Preserve the primary server rejection from `agent.start`.
            }
            throw failure
        }
    }

    override suspend fun closePane(params: PaneTarget) {
        request("pane.close", params, PaneTarget.serializer(), OkResponse.serializer())
    }

    override suspend fun renameAgent(params: AgentRenameParams) {
        request("agent.rename", params, AgentRenameParams.serializer(), AgentInfoResponse.serializer())
    }

    override suspend fun renameWorkspace(params: WorkspaceRenameParams) {
        request("workspace.rename", params, WorkspaceRenameParams.serializer(), WorkspaceInfoResponse.serializer())
    }

    /**
     * Opens one dedicated events channel. `events.subscribe` is the only herdr
     * request that remains open; all ordinary RPCs retain fresh channels.
     */
    override suspend fun subscribeToEvents(subscriptions: List<EventSubscription>): HerdrEventStream {
        stateMutex.withLock {
            if (eventsOpen) throw TransportError.EventsChannelAlreadyOpen
            eventsOpen = true
        }
        var lease: SshChannelAdmission.SshChannelAdmissionLease? = null
        try {
            lease = admission.acquire(SshChannelAdmission.ChannelClass.EVENTS)
            val session = withColdStartWake {
                openEventsSession(subscriptions, checkNotNull(lease))
            }
            return HerdrEventStream(session.events()) { session.close() }
        } catch (failure: Throwable) {
            lease?.release()
            stateMutex.withLock { eventsOpen = false }
            throw asTransportFailure(failure)
        }
    }

    override suspend fun attachTerminal(request: TerminalAttachRequest): TerminalAttachSession {
        stateMutex.withLock {
            if (terminalOpen) throw TransportError.TerminalChannelAlreadyOpen
            terminalOpen = true
        }
        var lease: SshChannelAdmission.SshChannelAdmissionLease? = null
        try {
            lease = admission.acquire(SshChannelAdmission.ChannelClass.ATTACH)
            val command = attachExecCommand(request, resolvedSocketPath())
            val channel = connection.openExec(
                command,
                PtyRequest(columns = request.cols, rows = request.rows),
            )
            val input = TerminalAttachInputQueue()
            val output = TerminalAttachOutputGate()
            val reader = scope.launch {
                runAttachChannel(channel, checkNotNull(lease), input, output)
            }
            return TerminalAttachSession(
                outputFactory = output::output,
                input = input,
                onEndStarted = output::beginExplicitEnd,
                ender = {
                    input.finish()
                    reader.cancelAndJoin()
                },
            )
        } catch (failure: Throwable) {
            lease?.release()
            stateMutex.withLock { terminalOpen = false }
            throw asTransportFailure(failure)
        }
    }

    override suspend fun stageImage(
        image: PreparedImage,
        progress: suspend (AttachmentStageProgress) -> Unit,
    ): StagedImage {
        validatePreparedFile(image.file, image.byteCount, PreparedImage.MAXIMUM_ENCODED_BYTE_COUNT.toLong())
        val path = stage(
            source = StagingSource(image.file, image.byteCount, "image.${image.format.fileExtension}"),
            progress = progress,
        )
        return StagedImage(path)
    }

    override suspend fun stageFile(
        file: PreparedFile,
        progress: suspend (AttachmentStageProgress) -> Unit,
    ): StagedFile {
        validatePreparedFile(file.file, file.byteCount, PreparedFile.MAXIMUM_BYTE_COUNT.toLong())
        val path = stage(StagingSource(file.file, file.byteCount, file.remoteFilename), progress)
        return StagedFile(path)
    }

    override suspend fun readNotificationRegistration(): ByteArray? =
        readPluginConfigFile(NOTIFICATION_REGISTRATION_FILE_NAME)

    override suspend fun replaceNotificationRegistration(contents: ByteArray) {
        replacePluginConfigFile(NOTIFICATION_REGISTRATION_FILE_NAME, contents)
    }

    override suspend fun readNotificationConfig(): ByteArray? =
        readPluginConfigFile(NOTIFICATION_CONFIG_FILE_NAME)

    override suspend fun replaceNotificationConfig(contents: ByteArray) {
        replacePluginConfigFile(NOTIFICATION_CONFIG_FILE_NAME, contents)
    }

    override suspend fun isConnected(): Boolean = stateMutex.withLock { connected }

    override suspend fun close() {
        val shouldClose = stateMutex.withLock {
            if (!connected) false else {
                connected = false
                true
            }
        }
        if (!shouldClose) return
        scope.cancel()
        try {
            connection.disconnect()
        } catch (failure: Throwable) {
            throw asTransportFailure(failure)
        }
    }

    private suspend fun startAgentAwaitingShell(
        launch: AgentLaunchRequest,
        paneID: String,
    ): AgentStartedResponse {
        val params = AgentStartParams(
            kind = launch.kind,
            name = launch.name,
            paneID = paneID,
            args = launch.arguments.takeIf(List<String>::isNotEmpty),
        )
        val deadlineNanos = System.nanoTime() + shellReadinessBudget.inWholeNanoseconds
        while (true) {
            try {
                return request("agent.start", params, AgentStartParams.serializer(), AgentStartedResponse.serializer())
            } catch (failure: HerdrApiError) {
                if (failure.code != "agent_pane_busy" ||
                    System.nanoTime() + shellReadinessRetryDelay.inWholeNanoseconds >= deadlineNanos
                ) {
                    throw failure
                }
                kotlinx.coroutines.delay(shellReadinessRetryDelay)
            }
        }
    }

    private suspend fun <P, R> request(
        method: String,
        params: P,
        paramsSerializer: KSerializer<P>,
        responseSerializer: KSerializer<R>,
    ): R = withColdStartWake {
        requireConnected()
        val requestID = UUID.randomUUID().toString()
        val requestLine = HerdrWire.requestLine(requestID, method, params, paramsSerializer)
        val socketPath = resolvedSocketPath()
        val response = withRequestDeadline {
            admission.withChannel(SshChannelAdmission.ChannelClass.ORDINARY_FORWARDING) {
                val channel = try {
                    connection.openStreamLocal(socketPath)
                } catch (failure: Throwable) {
                    throw classifyOpenFailure(socketPath, failure)
                }
                try {
                    channel.write(requestLine)
                    readResponseLine(channel)
                } finally {
                    closeQuietly(channel)
                }
            }
        }
        HerdrWire.decodeResult(response, requestID, responseSerializer)
    }


    private suspend fun <T> withColdStartWake(operation: suspend () -> T): T {
        try {
            return operation()
        } catch (failure: TransportError.StreamLocalOpenFailed) {
            try {
                wakeServer(failure.path)
            } catch (cancelled: TransportError.Cancelled) {
                throw cancelled
            } catch (timedOut: TransportError.TimedOut) {
                throw timedOut
            } catch (_: Throwable) {
                throw failure
            }
            return operation()
        }
    }

    private suspend fun openEventsSession(
        subscriptions: List<EventSubscription>,
        lease: SshChannelAdmission.SshChannelAdmissionLease,
    ): OpenEventsSession {
        requireConnected()
        val socketPath = resolvedSocketPath()
        val channel = try {
            connection.openStreamLocal(socketPath)
        } catch (failure: Throwable) {
            throw classifyOpenFailure(socketPath, failure)
        }
        try {
            val requestID = UUID.randomUUID().toString()
            channel.write(HerdrWire.subscribeRequestLine(requestID, subscriptions))
            val buffer = ByteLineBuffer()
            val ack = readNextLine(channel, buffer)
                ?: throw TransportError.ChannelFailed("events channel ended before acknowledgement")
            HerdrWire.decodeResult(ack, requestID, SubscriptionStartedResponse.serializer())
            return OpenEventsSession(channel, buffer, lease)
        } catch (failure: Throwable) {
            closeQuietly(channel)
            throw failure
        }
    }

    private suspend fun runAttachChannel(
        channel: SshExecChannel,
        lease: SshChannelAdmission.SshChannelAdmissionLease,
        input: TerminalAttachInputQueue,
        output: TerminalAttachOutputGate,
    ) {
        var terminalFailure: Throwable? = null
        try {
            coroutineScope {
                val inputPump = launch {
                    input.pump(
                        write = channel::write,
                        resize = channel::resize,
                    )
                }
                try {
                    val gate = AttachBootstrapGate()
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val bytes = channel.read() ?: break
                        gate.admit(bytes).takeIf(ByteArray::isNotEmpty)?.let(output::yield)
                    }
                    val exitStatus = channel.exitStatus()
                    gate.flush().takeIf(ByteArray::isNotEmpty)?.let(output::yield)
                    if (exitStatus != null && exitStatus != 0) {
                        throw TransportError.ChannelFailed("attach channel exited with status $exitStatus")
                    }
                } finally {
                    input.finish()
                    inputPump.cancelAndJoin()
                }
            }
        } catch (failure: CancellationException) {
            // Explicit end cancels this pump; output closes cleanly.
        } catch (failure: Throwable) {
            terminalFailure = asTransportFailure(failure)
        } finally {
            input.finish()
            closeQuietly(channel)
            lease.release()
            stateMutex.withLock { terminalOpen = false }
            output.finish(terminalFailure)
        }
    }

    private suspend fun stage(
        source: StagingSource,
        progress: suspend (AttachmentStageProgress) -> Unit,
    ): String {
        requireConnected()
        progress(AttachmentStageProgress(0, source.byteCount))
        val parent = createStageParentDirectory()
        return try {
            admission.withChannel(SshChannelAdmission.ChannelClass.ORDINARY_SESSION) {
                performStage(source, parent, progress)
            }
        } catch (failure: AttachmentStagingError) {
            throw failure
        } catch (failure: CancellationException) {
            throw AttachmentStagingError.Cancelled
        } catch (_: Throwable) {
            throw AttachmentStagingError.TransferFailed
        }
    }

    private suspend fun createStageParentDirectory(): String {
        val result = try {
            runExec(cLocaleCommand(settings.stageDirectoryCommand))
        } catch (failure: TransportError.Cancelled) {
            throw AttachmentStagingError.Cancelled
        } catch (_: Throwable) {
            throw AttachmentStagingError.RemoteTemporaryDirectoryFailed
        }
        val directory = markerValue(result.stdout, STAGE_DIRECTORY_OUTPUT_PREFIX)
            ?.takeIf(RemoteShellPath::isQuotableAbsolute)
            ?: throw AttachmentStagingError.RemoteTemporaryDirectoryFailed
        if (result.exitStatus != 0 || !result.reachedEof) {
            throw AttachmentStagingError.RemoteTemporaryDirectoryFailed
        }
        return directory
    }

    private suspend fun performStage(
        source: StagingSource,
        parentDirectory: String,
        progress: suspend (AttachmentStageProgress) -> Unit,
    ): String {
        val sftp = try {
            connection.sftp()
        } catch (failure: Throwable) {
            throw if (failure is SshException.NativeFailure) {
                AttachmentStagingError.SftpUnavailable
            } else {
                AttachmentStagingError.TransferFailed
            }
        }
        val remoteDirectory = "$parentDirectory/stage-${UUID.randomUUID()}"
        val finalPath = "$remoteDirectory/${source.remoteFilename}"
        var partPath: String? = "$finalPath.part"
        try {
            // Explicit 0700/0600 modes plus the parent command's umask protect
            // attachment bytes; rename preserves the private part-file mode.
            sftp.mkdir(remoteDirectory, MODE_PRIVATE_DIRECTORY)
            streamFile(source, checkNotNull(partPath), sftp, progress)
            currentCoroutineContext().ensureActive()
            sftp.rename(checkNotNull(partPath), finalPath)
            partPath = null
            return finalPath
        } catch (failure: CancellationException) {
            throw AttachmentStagingError.Cancelled
        } catch (failure: AttachmentStagingError) {
            throw failure
        } catch (_: Throwable) {
            throw AttachmentStagingError.TransferFailed
        } finally {
            partPath?.let { path ->
                try {
                    sftp.unlink(path)
                } catch (_: Throwable) {
                    // Compensation stays on the SFTP session already owned; never
                    // open a fresh session just to clean a cancelled upload.
                }
            }
            try {
                sftp.close()
            } catch (_: Throwable) {
                // The primary transfer outcome wins.
            }
        }
    }

    private suspend fun streamFile(
        source: StagingSource,
        remotePath: String,
        sftp: SshSftpSession,
        progress: suspend (AttachmentStageProgress) -> Unit,
    ) {
        val remote = try {
            sftp.open(remotePath, SFTP_OPEN_WRITE_CREATE_TRUNCATE, MODE_PRIVATE_FILE)
        } catch (_: Throwable) {
            throw AttachmentStagingError.TransferFailed
        }
        try {
            FileInputStream(source.file).use { input ->
                val chunk = ByteArray(64 * 1024)
                var transferred = 0L
                while (transferred < source.byteCount) {
                    currentCoroutineContext().ensureActive()
                    val wanted = min(chunk.size.toLong(), source.byteCount - transferred).toInt()
                    val count = withContext(Dispatchers.IO) { input.read(chunk, 0, wanted) }
                    if (count <= 0) throw AttachmentStagingError.ByteCountMismatch
                    remote.write(chunk.copyOf(count))
                    transferred += count
                    progress(AttachmentStageProgress(transferred, source.byteCount))
                }
                if (withContext(Dispatchers.IO) { input.read() } != -1) {
                    throw AttachmentStagingError.ByteCountMismatch
                }
            }
        } catch (failure: AttachmentStagingError) {
            throw failure
        } catch (failure: CancellationException) {
            throw failure
        } catch (_: Throwable) {
            throw AttachmentStagingError.LocalReadFailed
        } finally {
            try {
                remote.close()
            } catch (_: Throwable) {
                // The read/write failure remains the useful result.
            }
        }
    }

    private suspend fun readPluginConfigFile(name: String): ByteArray? {
        val directory = notificationPluginConfigDirectory()
        val path = "$directory/$name"
        val quoted = RemoteShellPath.quotedAbsolute(path)
            ?: throw NotificationRegistrationError.ReadFailed("The plugin config path is invalid.")
        val result = try {
            runExec(
                "/bin/sh -c 'if [ -f \"\$1\" ]; then chmod 600 \"\$1\" && " +
                    "printf \"$NOTIFICATION_FILE_MARKER\\n\" && cat \"\$1\"; fi' heeler $quoted",
            )
        } catch (failure: TransportError) {
            throw failure
        } catch (_: Throwable) {
            throw NotificationRegistrationError.ReadFailed("The SSH file operation failed.")
        }
        if (result.exitStatus != 0 || !result.reachedEof) {
            throw NotificationRegistrationError.ReadFailed("The SSH file operation failed.")
        }
        return result.stdout.contentsAfterMarker(NOTIFICATION_FILE_MARKER)
    }

    private suspend fun replacePluginConfigFile(name: String, contents: ByteArray) {
        val directory = notificationPluginConfigDirectory()
        val path = "$directory/$name"
        val quotedDirectory = RemoteShellPath.quotedAbsolute(directory)
            ?: throw NotificationRegistrationError.WriteFailed("The plugin config directory is invalid.")
        val quotedPath = RemoteShellPath.quotedAbsolute(path)
            ?: throw NotificationRegistrationError.WriteFailed("The plugin config path is invalid.")
        val encoded = Base64.encodeToString(contents, Base64.NO_WRAP)
        val temporary = "$path.tmp-${UUID.randomUUID()}"
        val quotedTemporary = RemoteShellPath.quotedAbsolute(temporary)
            ?: throw NotificationRegistrationError.WriteFailed("The plugin temporary path is invalid.")
        val command = "/bin/sh -c 'umask 077; chmod 700 \"\$2\" && " +
            "printf %s \"\$1\" | base64 -d > \"\$3\" && chmod 600 \"\$3\" && mv -f \"\$3\" \"\$4\"' " +
            "heeler '$encoded' $quotedDirectory $quotedTemporary $quotedPath"
        val result = try {
            runExec(command)
        } catch (failure: TransportError) {
            throw failure
        } catch (_: Throwable) {
            throw NotificationRegistrationError.WriteFailed("The SSH file operation failed.")
        }
        if (result.exitStatus != 0 || !result.reachedEof) {
            throw NotificationRegistrationError.WriteFailed("The SSH file operation failed.")
        }
    }

    private suspend fun notificationPluginConfigDirectory(): String = notificationDirectoryMutex.withLock {
        cachedNotificationDirectory ?: resolveNotificationConfigDirectory().also { cachedNotificationDirectory = it }
    }

    private suspend fun resolveNotificationConfigDirectory(): String {
        val listed = try {
            runNotificationPluginProbe(settings.pluginListCommand)
        } catch (failure: NotificationRegistrationError) {
            throw failure
        }
        val pluginID = installedNotificationPluginID(listed)
        val command = settings.notificationConfigDirCommand.replace(
            SshTransportSettings.NOTIFICATION_PLUGIN_ID_TOKEN,
            pluginID,
        )
        val response = runNotificationPluginProbe(command)
        return markerValue(response, PLUGIN_CONFIG_DIRECTORY_OUTPUT_PREFIX)
            ?.takeIf(RemoteShellPath::isQuotableAbsolute)
            ?: throw NotificationRegistrationError.PluginProbeFailed("The plugin config directory response was invalid.")
    }

    private suspend fun runNotificationPluginProbe(command: String): ByteArray {
        val result = try {
            runExec(cLocaleCommand(command))
        } catch (failure: TransportError) {
            throw failure
        } catch (_: Throwable) {
            throw NotificationRegistrationError.PluginProbeFailed("The Host plugin probe failed.")
        }
        if (result.exitStatus != 0 || !result.reachedEof) {
            throw NotificationRegistrationError.PluginProbeFailed("The Host plugin probe failed.")
        }
        return result.stdout
    }

    private fun installedNotificationPluginID(listOutput: ByteArray): String {
        val plugins = try {
            val root = HerdrWire.json.parseToJsonElement(listOutput.decodeToString()).jsonObject
            root["result"]?.jsonObject?.get("plugins")?.jsonArray.orEmpty()
        } catch (_: Throwable) {
            throw NotificationRegistrationError.PluginProbeFailed("The plugin list response was invalid.")
        }
        val enabledIDs = plugins.mapNotNull { element ->
            val objectValue = element as? JsonObject ?: return@mapNotNull null
            val enabled = objectValue["enabled"]?.jsonPrimitive?.booleanOrNull
            objectValue["plugin_id"]?.jsonPrimitive?.contentOrNull?.takeIf { enabled != false }
        }.toSet()
        return (listOf(SshTransportSettings.NOTIFICATION_PLUGIN_ID) +
            SshTransportSettings.LEGACY_NOTIFICATION_PLUGIN_IDS)
            .firstOrNull(enabledIDs::contains)
            ?: throw NotificationRegistrationError.PluginNotInstalled
    }

    private suspend fun resolvedSocketPath(): String = when (val location = settings.socket) {
        is HerdrSocketLocation.AbsolutePath -> location.path
        else -> location.path(remoteHomeDirectory())
    }

    /** Resolves remote `$HOME` once per Host for home-relative socket paths. */
    private suspend fun remoteHomeDirectory(): String = homeMutex.withLock {
        cachedHomeDirectory ?: run {
            val result = runExec(cLocaleCommand(settings.homeCommand))
            val home = markerValue(result.stdout, HOME_OUTPUT_PREFIX)
                ?.takeIf(RemoteShellPath::isQuotableAbsolute)
                ?: throw TransportError.HomeDirectoryUnresolvable(
                    "home command printed: ${result.stdout.preview()}",
                )
            if (result.exitStatus != 0 || !result.reachedEof) {
                throw TransportError.HomeDirectoryUnresolvable("home command failed")
            }
            home.also { cachedHomeDirectory = it }
        }
    }

    private suspend fun wakeServer(socketPath: String) {
        val command = wakeExecCommand(socketPath)
        val result = runExec(command)
        if (result.exitStatus != 0 || !result.reachedEof) {
            throw TransportError.ChannelFailed("herdr wake command failed: ${result.stderr.preview()}")
        }
    }

    /**
     * libssh2 cannot distinguish a missing socket from SSH forwarding policy.
     * Probe `test -S` only after an open failure to retain the honest taxonomy.
     */
    private suspend fun classifyOpenFailure(socketPath: String, failure: Throwable): Throwable {
        if (failure is TransportError || failure is CancellationException || failure is SshException.TimedOut) {
            return asTransportFailure(failure)
        }
        val quoted = RemoteShellPath.quotedAbsolute(socketPath) ?: return TransportError.SocketNotFound(socketPath)
        return try {
            val result = runExec("/bin/sh -c 'test -S \"\$1\"' heeler $quoted")
            if (result.exitStatus == 1) TransportError.SocketNotFound(socketPath)
            else TransportError.StreamLocalOpenFailed(socketPath)
        } catch (exception: TransportError.Cancelled) {
            exception
        } catch (exception: TransportError.TimedOut) {
            exception
        } catch (_: Throwable) {
            TransportError.StreamLocalOpenFailed(socketPath)
        }
    }

    private suspend fun runHostCommand(command: String): ByteArray {
        val result = runExec(cLocaleCommand(command))
        if (!result.reachedEof) throw TransportError.ChannelFailed("Host command closed before EOF")
        return result.stdout
    }

    private suspend fun runExec(command: String): ExecResult = try {
        withRequestDeadline {
            admission.withChannel(SshChannelAdmission.ChannelClass.ORDINARY_SESSION) {
                val channel = connection.openExec(command)
                try {
                    coroutineScope {
                        val stdout = async { readAll(channel) }
                        val stderr = async { readAllStderr(channel) }
                        ExecResult(stdout.await(), stderr.await(), channel.exitStatus() ?: -1, reachedEof = true)
                    }
                } finally {
                    closeQuietly(channel)
                }
            }
        }
    } catch (failure: Throwable) {
        throw asTransportFailure(failure)
    }

    private suspend fun readResponseLine(channel: SshDataChannel): ByteArray {
        val buffer = ByteLineBuffer()
        return readNextLine(channel, buffer)
            ?: throw TransportError.MalformedResponse("stream-local channel closed before a response line")
    }

    private suspend fun readNextLine(channel: SshDataChannel, buffer: ByteLineBuffer): ByteArray? {
        while (true) {
            buffer.takeLine()?.let { return it }
            val chunk = channel.read() ?: return buffer.takeRemainder()
            buffer.append(chunk)
            if (buffer.size > MAXIMUM_RESPONSE_BYTES) {
                throw TransportError.MalformedResponse("response line exceeds $MAXIMUM_RESPONSE_BYTES bytes")
            }
        }
    }

    private suspend fun readAll(channel: SshDataChannel): ByteArray {
        val output = ByteArrayOutputStream()
        while (true) {
            val chunk = channel.read() ?: return output.toByteArray()
            output.write(chunk)
            if (output.size() > MAXIMUM_RESPONSE_BYTES) {
                throw TransportError.MalformedResponse("exec output exceeds $MAXIMUM_RESPONSE_BYTES bytes")
            }
        }
    }

    private suspend fun readAllStderr(channel: SshExecChannel): ByteArray {
        val output = ByteArrayOutputStream()
        while (true) {
            val chunk = channel.readStderr() ?: return output.toByteArray()
            output.write(chunk)
            if (output.size() > MAXIMUM_RESPONSE_BYTES) {
                throw TransportError.MalformedResponse("exec stderr exceeds $MAXIMUM_RESPONSE_BYTES bytes")
            }
        }
    }

    private suspend fun <T> withRequestDeadline(operation: suspend () -> T): T = try {
        AsyncDeadline.run(settings.requestTimeout, operation = operation)
    } catch (_: AsyncDeadlineError) {
        throw TransportError.TimedOut
    } catch (_: CancellationException) {
        throw TransportError.Cancelled
    }

    private suspend fun requireConnected() {
        if (!stateMutex.withLock { connected }) {
            throw TransportError.SshUnreachable("The SSH connection is closed.")
        }
    }

    private fun asTransportFailure(failure: Throwable): TransportError = when (failure) {
        is TransportError -> failure
        is HerdrApiError -> TransportError.ApiRejected(failure.code, failure.serverMessage)
        is SshException.TimedOut -> TransportError.TimedOut
        is CancellationException -> TransportError.Cancelled
        is SshException.Closed -> TransportError.SshUnreachable(failure.message.orEmpty())
        else -> TransportError.ChannelFailed(failure.toString())
    }

    private fun attachExecCommand(request: TerminalAttachRequest, socketPath: String): String {
        val targetUnsafe = request.target.any { it == '\'' || it == '\\' || it.isISOControl() }
        if (settings.attachCommand.isBlank() || request.target.isBlank() || targetUnsafe) {
            throw TransportError.ChannelFailed("attach target cannot be quoted for the remote command")
        }
        val quotedSocket = RemoteShellPath.quotedAbsolute(socketPath)
            ?: throw TransportError.ChannelFailed("The remote socket path cannot be quoted safely.")
        val takeover = if (request.takeover) " --takeover" else ""
        // The marker prints immediately before exec so account-shell chatter stays off terminal.
        return "/bin/sh -c 'export HERDR_SOCKET_PATH=\"\$2\"; " +
            "printf \"${AttachBootstrapHandshake.MARKER_PRINTF_FORMAT}\"; " +
            "exec ${settings.attachCommand} \"\$1\"$takeover' attach '${request.target}' $quotedSocket"
    }

    private fun wakeExecCommand(socketPath: String): String {
        val quotedSocket = RemoteShellPath.quotedAbsolute(socketPath)
            ?: throw TransportError.ChannelFailed("The remote socket path cannot be quoted safely.")
        return when (val location = settings.socket) {
            is HerdrSocketLocation.NamedSession -> cLocaleCommand(
                "/bin/sh -c 'export HERDR_SOCKET_PATH=\"\$1\"; export HERDR_SESSION=\"\$2\"; " +
                    "${settings.wakeCommand} < /dev/null' wake $quotedSocket ${location.name}",
            )
            else -> cLocaleCommand(
                "/bin/sh -c 'export HERDR_SOCKET_PATH=\"\$1\"; " +
                    "${settings.wakeCommand} < /dev/null' wake $quotedSocket",
            )
        }
    }

    private fun markerValue(output: ByteArray, prefix: String): String? = output.decodeToString()
        .lineSequence()
        .toList()
        .asReversed()
        .firstOrNull { it.startsWith(prefix) }
        ?.removePrefix(prefix)
        ?.removeSuffix("\r")

    private fun cLocaleCommand(command: String): String = "LC_ALL=C $command"

    private fun validatePreparedFile(file: File, byteCount: Long, limit: Long) {
        if (byteCount <= 0 || byteCount > limit || !file.isFile || file.length() != byteCount) {
            throw AttachmentStagingError.InvalidPreparedSource
        }
    }

    private suspend fun closeQuietly(channel: SshDataChannel) {
        try {
            channel.close()
        } catch (_: Throwable) {
            // The result that required cleanup remains authoritative.
        }
    }

    private data class StagingSource(val file: File, val byteCount: Long, val remoteFilename: String)
    private data class ExecResult(
        val stdout: ByteArray,
        val stderr: ByteArray,
        val exitStatus: Int,
        val reachedEof: Boolean,
    )

    /** Owns an acknowledged long-lived events channel and exactly one reader. */
    private inner class OpenEventsSession(
        private val channel: SshDataChannel,
        private val initial: ByteLineBuffer,
        private val lease: SshChannelAdmission.SshChannelAdmissionLease,
    ) {
        private val closed = AtomicBoolean(false)
        private val readerClaimed = AtomicBoolean(false)

        fun events(): Flow<HerdrEvent> = flow {
            if (!readerClaimed.compareAndSet(false, true)) {
                throw TransportError.EventsChannelAlreadyOpen
            }
            try {
                while (true) {
                    val line = readNextLine(channel, initial) ?: break
                    HerdrWire.decodeEvent(line)?.let { emit(it) }
                }
                throw TransportError.ChannelFailed("events channel closed by remote")
            } catch (failure: CancellationException) {
                throw failure
            } catch (failure: Throwable) {
                throw asTransportFailure(failure)
            } finally {
                close()
            }
        }.buffer(HerdrEventStream.BUFFER_LIMIT)

        suspend fun close() {
            if (!closed.compareAndSet(false, true)) return
            closeQuietly(channel)
            lease.release()
            stateMutex.withLock { eventsOpen = false }
        }
    }
}

private fun SshCredentials.toNative(): SshAuthentication = when (this) {
    is SshCredentials.Password -> SshAuthentication.Password(password)
    is SshCredentials.PublicKey -> SshAuthentication.PublicKey(privateKeyPem, publicKeyOpenSsh, passphrase)
}

private fun ByteArray.preview(): String = copyOfRange(0, minOf(size, 200)).decodeToString()

/** Returns file bytes after the marker line, preserving an existing empty file. */
private fun ByteArray.contentsAfterMarker(marker: String): ByteArray? {
    val bytes = marker.encodeToByteArray()
    if (size <= bytes.size) return null
    for (offset in 0..(size - bytes.size - 1)) {
        if (offset > 0 && this[offset - 1] != '\n'.code.toByte()) continue
        if (!bytes.indices.all { this[offset + it] == bytes[it] }) continue
        val lineEnd = offset + bytes.size
        if (this[lineEnd] == '\n'.code.toByte()) return copyOfRange(lineEnd + 1, size)
    }
    return null
}

/** Allocation-conscious newline splitter for one NDJSON channel. */
private class ByteLineBuffer {
    private var bytes = ByteArray(32 * 1024)
    private var length = 0

    val size: Int get() = length

    fun append(chunk: ByteArray) {
        ensureCapacity(length + chunk.size)
        chunk.copyInto(bytes, length)
        length += chunk.size
    }

    fun takeLine(): ByteArray? {
        val newline = bytes.indexOf('\n'.code.toByte(), 0, length)
        if (newline < 0) return null
        val line = bytes.copyOfRange(0, newline)
        val remaining = length - newline - 1
        if (remaining > 0) bytes.copyInto(bytes, 0, newline + 1, length)
        length = remaining
        return line
    }

    fun takeRemainder(): ByteArray? {
        if (length == 0) return null
        return bytes.copyOfRange(0, length).also { length = 0 }
    }

    private fun ensureCapacity(required: Int) {
        if (required <= bytes.size) return
        var capacity = bytes.size
        while (capacity < required) capacity = capacity * 2
        bytes = bytes.copyOf(capacity)
    }
}

private fun ByteArray.indexOf(value: Byte, start: Int, endExclusive: Int): Int {
    for (index in start until endExclusive) if (this[index] == value) return index
    return -1
}
