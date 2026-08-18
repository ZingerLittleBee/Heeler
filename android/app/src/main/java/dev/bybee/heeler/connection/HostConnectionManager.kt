package dev.bybee.heeler.connection

import dev.bybee.heeler.core.crypto.DeviceKeyStore
import dev.bybee.heeler.core.transport.EventSubscription
import dev.bybee.heeler.core.transport.EventsSession
import dev.bybee.heeler.core.transport.EventsSessionStatus
import dev.bybee.heeler.core.transport.EventsSessionUpdate
import dev.bybee.heeler.core.transport.GlobalEventKind
import dev.bybee.heeler.core.transport.HeelerSshTransport
import dev.bybee.heeler.core.transport.HerdrSocketLocation
import dev.bybee.heeler.core.transport.HostKeyCandidate
import dev.bybee.heeler.core.transport.HostKeyPolicy
import dev.bybee.heeler.core.transport.KnownHostsStore
import dev.bybee.heeler.core.transport.SshCredentials
import dev.bybee.heeler.core.transport.SshJumpSettings
import dev.bybee.heeler.core.transport.SshTransportSettings
import dev.bybee.heeler.core.transport.Transport
import dev.bybee.heeler.core.transport.TransportError
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostAuth
import dev.bybee.heeler.data.HostStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap
import kotlin.time.Duration.Companion.seconds

/**
 * The single SSH/events owner for every configured Host. A Host's transport is
 * never shared by independently-dialled callers: the manager owns one
 * [EventsSession], exposes its state, and tears it down after the background
 * grace period.
 */
class HostConnectionManager(
    private val hostStore: HostStore,
    private val deviceKeyStore: DeviceKeyStore,
    private val knownHosts: KnownHostsStore,
    private val scope: CoroutineScope,
) {
    private val recordsLock = Any()
    private val records = mutableMapOf<String, HostRecord>()
    private val stateFlows = ConcurrentHashMap<String, MutableStateFlow<HostConnectionState>>()
    private val generations = ConcurrentHashMap<String, Long>()

    @Volatile
    private var isForeground = false
    private var backgroundGraceJob: Job? = null

    init {
        scope.launch {
            hostStore.hosts.collect(::reconcileHosts)
        }
    }

    /** Current connection state for [hostId], including connection telemetry. */
    fun state(hostId: String): StateFlow<HostConnectionState> = stateFlow(hostId).asStateFlow()

    /**
     * Monotonic Host-local connection identity. Callers must compare it after
     * a suspend boundary before applying any result derived from a Transport.
     */
    fun generation(hostId: String): Long = synchronized(recordsLock) { generations[hostId] ?: 0L }

    /** Ordered session updates tagged with the connection generation that emitted them. */
    fun events(hostId: String): Flow<HostConnectionUpdate> =
        connectionFor(hostId)?.updates ?: emptyFlow()

    /**
     * Borrows the current live Transport. This is deliberately an explicit
     * failure while disconnected instead of opening a second SSH connection.
     */
    suspend fun transport(hostId: String): Transport {
        val record = connectionFor(hostId)
            ?: throw TransportError.SshUnreachable("This Host is no longer configured.")
        return record.session.withTransport { it }
    }

    /** Replaces snapshot-derived pane subscriptions on the Host's one events channel. */
    suspend fun updateSubscriptions(hostId: String, subscriptions: List<EventSubscription>) {
        val record = connectionFor(hostId)
            ?: throw TransportError.SshUnreachable("This Host is no longer configured.")
        record.session.updateSubscriptions(subscriptions)
    }

    /** Restarts one Host's events session without disturbing other Hosts. */
    suspend fun reconnect(hostId: String) {
        connectionFor(hostId)?.retryIfIdle()
    }

    /** Closes one Host's events and SSH channels; it can reconnect on foreground. */
    suspend fun close(hostId: String) {
        connectionFor(hostId)?.session?.suspendSession()
    }

    /** Re-proves every Host on foregrounding without racing a live connection attempt. */
    suspend fun revalidateAll() = coroutineScope {
        snapshotRecords().forEach { record ->
            launch { record.revalidateFromForeground() }
        }
    }

    /** Deliberate background teardown for every Host. */
    suspend fun suspendAll() = coroutineScope {
        snapshotRecords().forEach { record ->
            launch { record.session.suspendSession() }
        }
    }

    /**
     * Updates snapshot-sync telemetry for a connected Host. The generation
     * check prevents a stale projection from annotating its replacement.
     */
    fun setSyncError(hostId: String, generation: Long, message: String?) {
        val record = connectionFor(hostId) ?: return
        if (generation != generation(hostId)) return
        record.syncError = message
        val current = stateFlow(hostId).value
        if (current is HostConnectionState.Connected) {
            stateFlow(hostId).value = current.copy(syncError = message)
        }
    }

    /** Called from [androidx.lifecycle.ProcessLifecycleOwner] when the app is visible. */
    fun onForeground() {
        backgroundGraceJob?.cancel()
        backgroundGraceJob = null
        isForeground = true
        scope.launch { revalidateAll() }
    }

    /**
     * Starts the bounded background grace period. A quick return preserves the
     * event channel; a longer absence closes every session deliberately.
     */
    fun onBackground() {
        isForeground = false
        backgroundGraceJob?.cancel()
        backgroundGraceJob = scope.launch {
            delay(BACKGROUND_GRACE_PERIOD.inWholeMilliseconds)
            if (!isForeground) suspendAll()
        }
    }

    /** Permanently releases all connections when the application is destroyed. */
    suspend fun closeAll() {
        backgroundGraceJob?.cancel()
        backgroundGraceJob = null
        val retired = synchronized(recordsLock) {
            records.values.toList().also { records.clear() }
        }
        retired.forEach { record ->
            bumpGeneration(record.host.id)
            record.end()
            stateFlow(record.host.id).value = HostConnectionState.Suspended
        }
    }

    private fun reconcileHosts(hosts: List<Host>) {
        val uniqueHosts = hosts.associateBy(Host::id)
        val retired = mutableListOf<HostRecord>()
        val additions = mutableListOf<Host>()
        synchronized(recordsLock) {
            records.entries.iterator().let { entries ->
                while (entries.hasNext()) {
                    val entry = entries.next()
                    val replacement = uniqueHosts[entry.key]
                    if (replacement == entry.value.host) continue
                    retired += entry.value
                    entries.remove()
                    generations[entry.key] = (generations[entry.key] ?: 0L) + 1L
                }
            }
            uniqueHosts.values.forEach { host ->
                if (records[host.id] == null) additions += host
            }
        }
        retired.forEach { record ->
            scope.launch { record.end() }
            stateFlow(record.host.id).value = HostConnectionState.Suspended
        }
        additions.forEach(::installRecord)
    }

    private fun installRecord(host: Host) {
        val record = HostRecord(
            host = host,
            session = EventsSession(
                subscriptions = baseSubscriptions,
                connect = { connect(host) },
            ),
        )
        val installed = synchronized(recordsLock) {
            if (records.containsKey(host.id)) false else {
                records[host.id] = record
                true
            }
        }
        if (!installed) return
        stateFlow(host.id).value = HostConnectionState.Suspended
        record.start()
        if (isForeground) {
            scope.launch { record.revalidateFromForeground() }
        }
    }

    private fun connectionFor(hostId: String): HostRecord? {
        synchronized(recordsLock) { records[hostId] }?.let { return it }
        hostStore.hosts.value.firstOrNull { it.id == hostId }?.let(::installRecord)
        return synchronized(recordsLock) { records[hostId] }
    }

    private fun snapshotRecords(): List<HostRecord> = synchronized(recordsLock) { records.values.toList() }

    private fun stateFlow(hostId: String): MutableStateFlow<HostConnectionState> =
        stateFlows.getOrPut(hostId) { MutableStateFlow(HostConnectionState.Suspended) }

    private fun bumpGeneration(hostId: String): Long = synchronized(recordsLock) {
        val next = (generations[hostId] ?: 0L) + 1L
        generations[hostId] = next
        next
    }

    private suspend fun connect(host: Host): Transport {
        val credentials = credentialsFor(host)
        val socket = host.sessionName?.let(HerdrSocketLocation::NamedSession)
            ?: HerdrSocketLocation.DefaultSession
        val policy = HostKeyPolicy(knownHosts) { candidate ->
            host.hostKeyFingerprint.isNotBlank() &&
                candidate.fingerprint.displayString == host.hostKeyFingerprint
        }
        return HeelerSshTransport.connect(
            SshTransportSettings(
                host = host.address,
                port = host.port,
                username = host.username,
                credentials = credentials,
                hostKeyPolicy = policy,
                socket = socket,
                jump = host.jumpHost?.let { jump ->
                    SshJumpSettings(
                        host = jump.address,
                        port = jump.port,
                        username = jump.username,
                        credentials = credentials,
                    )
                },
            ),
        )
    }

    private suspend fun credentialsFor(host: Host): SshCredentials = when (host.auth) {
        HostAuth.DeviceKey -> withContext(Dispatchers.Default) {
            SshCredentials.PublicKey(
                privateKeyPem = deviceKeyStore.loadOrCreate().openSshPrivateKeyPem().encodeToByteArray(),
            )
        }
        is HostAuth.Password -> {
            val password = hostStore.password(host) ?: throw TransportError.AuthenticationFailed
            SshCredentials.Password(password)
        }
    }

    private inner class HostRecord(
        val host: Host,
        val session: EventsSession,
    ) {
        val updates = MutableSharedFlow<HostConnectionUpdate>(
            replay = 1,
            extraBufferCapacity = 64,
        )
        @Volatile var syncError: String? = null
        @Volatile var latencyMillis: Long? = null
        private var sawTransport = false
        private var sessionTransportGeneration: ULong = 0u
        @Volatile var lastSessionStatus: EventsSessionStatus = EventsSessionStatus.Suspended
        /**
         * A HostRecord owns exactly one activation/retry at a time. The guard
         * stays set until the session reports a terminal state, rather than
         * consulting the UI state flow, which intentionally trails updates.
         */
        private val lifecycleMutex = Mutex()
        private var lifecycleInFlight = false
        private var updatesJob: Job? = null
        private var latencyJob: Job? = null

        fun start() {
            updatesJob = scope.launch {
                session.updates.collect { update ->
                    if (currentRecord(host.id) !== this@HostRecord) return@collect
                    if (apply(update)) {
                        updates.emit(HostConnectionUpdate(generation(host.id), update))
                    }
                }
            }
            latencyJob = scope.launch {
                session.latencyUpdates.collect { latency ->
                    if (currentRecord(host.id) !== this@HostRecord) return@collect
                    latencyMillis = latency.inWholeMilliseconds
                    val current = state(host.id).value
                    if (current is HostConnectionState.Connected) {
                        stateFlow(host.id).value = current.copy(latencyMillis = latencyMillis)
                    }
                }
            }
        }

        suspend fun end() {
            updatesJob?.cancel()
            latencyJob?.cancel()
            session.end()
        }

        suspend fun revalidateFromForeground() {
            when (
                lifecycleMutex.withLock {
                    if (lifecycleInFlight) {
                        null
                    } else {
                        when (lastSessionStatus) {
                            is EventsSessionStatus.Failed -> {
                                lifecycleInFlight = true
                                ForegroundAction.RETRY
                            }
                            EventsSessionStatus.Suspended -> {
                                lifecycleInFlight = true
                                ForegroundAction.RESUME
                            }
                            EventsSessionStatus.Connected -> ForegroundAction.REVALIDATE
                            is EventsSessionStatus.Reconnecting,
                            EventsSessionStatus.Ended -> null
                        }
                    }
                }
            ) {
                ForegroundAction.RETRY -> {
                    stateFlow(host.id).value = HostConnectionState.Connecting
                    runLifecycleAction(session::retry)
                }
                ForegroundAction.RESUME -> {
                    stateFlow(host.id).value = HostConnectionState.Connecting
                    runLifecycleAction(session::resume)
                }
                ForegroundAction.REVALIDATE -> session.revalidate()
                null -> Unit
            }
        }

        suspend fun retryIfIdle() {
            if (!claimLifecycle()) return
            stateFlow(host.id).value = HostConnectionState.Connecting
            runLifecycleAction(session::retry)
        }

        private suspend fun claimLifecycle(): Boolean = lifecycleMutex.withLock {
            if (lifecycleInFlight) false else {
                lifecycleInFlight = true
                true
            }
        }

        private suspend fun runLifecycleAction(action: suspend () -> Unit) {
            try {
                action()
            } catch (failure: Throwable) {
                releaseLifecycle()
                throw failure
            }
        }

        private suspend fun markLifecycleInFlight() {
            lifecycleMutex.withLock { lifecycleInFlight = true }
        }

        private suspend fun releaseLifecycle() {
            lifecycleMutex.withLock { lifecycleInFlight = false }
        }

        private suspend fun apply(update: EventsSessionUpdate): Boolean {
            when (update) {
                is EventsSessionUpdate.Event -> Unit
                is EventsSessionUpdate.Status -> {
                    val status = update.status
                    if (
                        status is EventsSessionStatus.Failed &&
                        status.failure == TransportError.EventsChannelAlreadyOpen
                    ) {
                        releaseLifecycle()
                        if (sawTransport) {
                            stateFlow(host.id).value = HostConnectionState.Connected(
                                latencyMillis = latencyMillis,
                                syncError = syncError,
                            )
                        }
                        return false
                    }

                    lastSessionStatus = status
                    when (status) {
                        EventsSessionStatus.Connected -> {
                            releaseLifecycle()
                            val sessionGeneration = session.transportGeneration
                            if (!sawTransport || sessionTransportGeneration != sessionGeneration) {
                                sawTransport = true
                                sessionTransportGeneration = sessionGeneration
                                bumpGeneration(host.id)
                            }
                            stateFlow(host.id).value = HostConnectionState.Connected(
                                latencyMillis = latencyMillis,
                                syncError = syncError,
                            )
                        }
                        is EventsSessionStatus.Reconnecting -> {
                            markLifecycleInFlight()
                            syncError = null
                            stateFlow(host.id).value = HostConnectionState.Reconnecting(
                                error = status.failure,
                                attempt = status.attempt,
                                retryInMillis = status.delay.inWholeMilliseconds,
                            )
                        }
                        is EventsSessionStatus.Failed -> {
                            releaseLifecycle()
                            syncError = null
                            stateFlow(host.id).value = HostConnectionState.Failed(status.failure)
                        }
                        EventsSessionStatus.Suspended,
                        EventsSessionStatus.Ended -> {
                            releaseLifecycle()
                            syncError = null
                            stateFlow(host.id).value = HostConnectionState.Suspended
                        }
                    }
                }
            }
            return true
        }

    }
        private enum class ForegroundAction {
            RETRY,
            RESUME,
            REVALIDATE,
        }

    private fun currentRecord(hostId: String): HostRecord? = synchronized(recordsLock) { records[hostId] }

    companion object {
        val BACKGROUND_GRACE_PERIOD = 20.seconds

        private val baseSubscriptions = listOf(
            GlobalEventKind.PANE_AGENT_DETECTED,
            GlobalEventKind.PANE_CLOSED,
            GlobalEventKind.PANE_EXITED,
            GlobalEventKind.WORKSPACE_CREATED,
            GlobalEventKind.WORKSPACE_RENAMED,
            GlobalEventKind.WORKSPACE_METADATA_UPDATED,
            GlobalEventKind.WORKSPACE_CLOSED,
        ).map { EventSubscription.Global(it) }
    }
}

/** Console-facing events from a Host's one long-lived events session. */
data class HostConnectionUpdate(
    val generation: Long,
    val update: EventsSessionUpdate,
)

/** State surfaced to the Console and Host UI without exposing SSH implementation details. */
sealed interface HostConnectionState {
    data object Connecting : HostConnectionState
    data class Connected(
        val latencyMillis: Long? = null,
        val syncError: String? = null,
    ) : HostConnectionState
    data class Reconnecting(
        val error: TransportError,
        val attempt: Int,
        val retryInMillis: Long,
    ) : HostConnectionState
    data class Failed(val error: TransportError) : HostConnectionState
    data object Suspended : HostConnectionState
}
