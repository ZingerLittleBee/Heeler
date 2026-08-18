package dev.bybee.heeler.core.transport

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.nanoseconds
import kotlin.time.Duration.Companion.seconds
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Bounded backoff for transient events-channel failures: capped exponential
 * delay with unlimited attempts. Action-required failures stop and surface
 * their exact cause instead of retrying forever.
 */
data class ReconnectPolicy(
    val initialDelay: Duration,
    val multiplier: Int,
    val maxDelay: Duration,
) {
    companion object {
        val DEFAULT = ReconnectPolicy(1.seconds, 2, 30.seconds)
    }

    /** Delay before one-based [attempt]. */
    fun delayBeforeAttempt(attempt: Int): Duration {
        var delay = initialDelay
        repeat((attempt - 1).coerceAtLeast(0)) {
            if (delay < maxDelay) delay = (delay * multiplier.coerceAtLeast(1)).coerceAtMost(maxDelay)
        }
        return delay.coerceAtMost(maxDelay)
    }
}

/**
 * Events keepalive policy. The transport seam deliberately exposes no
 * SSH-specific heartbeat: ping over ordinary RPC exercises SSH, forwarding,
 * and herdr, keeps NAT mappings fresh, and is deadline-bounded.
 */
data class KeepalivePolicy(val interval: Duration) {
    companion object {
        val DEFAULT = KeepalivePolicy(30.seconds)
    }
}

/** Where the events session stands; UI derives staleness from this. */
sealed interface EventsSessionStatus {
    /** A live events channel; every connection requires a snapshot re-sync. */
    data object Connected : EventsSessionStatus
    /** The next retry starts after [delay]; state may be stale. */
    data class Reconnecting(
        val attempt: Int,
        val delay: Duration,
        val failure: TransportError,
    ) : EventsSessionStatus
    /** Reconnecting cannot repair this failure. */
    data class Failed(val failure: TransportError) : EventsSessionStatus
    /** Explicit background teardown. */
    data object Suspended : EventsSessionStatus
    /** [EventsSession.end] is terminal. */
    data object Ended : EventsSessionStatus
}

/** Status transitions and remote events interleaved in arrival order. */
sealed interface EventsSessionUpdate {
    data class Status(val status: EventsSessionStatus) : EventsSessionUpdate
    data class Event(val event: HerdrEvent) : EventsSessionUpdate
}

/**
 * The self-healing events channel for one Host. It owns the Host Transport,
 * keeps its dedicated `events.subscribe` channel across network blips and
 * foreground/background changes, and reports transitions so the UI can show
 * staleness.
 *
 * Layer-honest reconnect: a dropped channel re-subscribes on its live SSH
 * connection. A dead SSH connection (or a timed-out request that cannot be
 * trusted) is closed and established through [connect], then pinged first on
 * its new connection path before re-subscribing.
 *
 * Pane-scoped subscriptions are snapshot-derived and must never outlive their
 * connection: one exited pane makes `events.subscribe` all-or-nothing fail
 * with `pane_not_found`. [dropPaneSubscriptions] keeps one stale pane from
 * wedging a Host offline forever.
 */
class EventsSession(
    subscriptions: List<EventSubscription>,
    private val connect: suspend () -> Transport,
    private val reconnectPolicy: ReconnectPolicy = ReconnectPolicy.DEFAULT,
    private val keepalive: KeepalivePolicy? = KeepalivePolicy.DEFAULT,
    updatesBufferLimit: Int = HerdrEventStream.BUFFER_LIMIT,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private enum class Phase { SUSPENDED, ACTIVE, ENDED }

    /**
     * Ordered updates for one consumer. The buffer is bounded; overflow emits
     * [HerdrEvent.eventsDropped] so consumers re-snapshot rather than trusting
     * incomplete deltas.
     */
    val updates: Flow<EventsSessionUpdate>

    /** Latest measured ping latency; it is telemetry, not ordered convergence. */
    private val mutableLatencyUpdates = MutableSharedFlow<Duration>(replay = 0, extraBufferCapacity = 1)
    val latencyUpdates: Flow<Duration> = mutableLatencyUpdates

    private val updatesRelay = EventsUpdateRelay(updatesBufferLimit)
    private val stateMutex = Mutex()
    private val lifecycleMutex = Mutex()
    private val terminalMutex = Mutex()

    private var subscriptions: List<EventSubscription> = subscriptions
    private var phase = Phase.SUSPENDED
    private var currentTransport: Transport? = null
    /** Monotonic identity for installed transports; subscription reconnects reuse it. */
    var transportGeneration: ULong = 0u
        private set
    private var hasEstablishedTransport = false
    /** A successful events stream makes a later transient socket-open failure recoverable. */
    private var hasEstablishedEventsStream = false
    private var transportSuspect = false
    private var pendingKeepaliveFailure: TransportError? = null
    private var lastConnectionActivityNanos: Long? = null
    private var resubscribeRequested = false
    private var liveStream: HerdrEventStream? = null
    private var activationGeneration: ULong = 0u
    private var runJob: Job? = null
    private var keepaliveJob: Job? = null

    init {
        require(updatesBufferLimit > 0) { "Events updates buffer must be positive." }
        updates = updatesRelay.flow
    }

    /** Activates a fresh or suspended session. No-op while active or ended. */
    suspend fun resume() {
        lifecycleMutex.withLock { activateIfSuspended() }
    }

    /** Restarts a session after an actionable failure or explicit user retry. */
    suspend fun retry() {
        lifecycleMutex.withLock {
            if (stateMutex.withLock { phase == Phase.ACTIVE }) {
                deactivate(emitStatus = false)
            }
            activateIfSuspended()
        }
    }

    /**
     * Re-proves an apparently live session when foregrounding. Frozen sockets
     * do not necessarily end their event flow; a failed ping feeds the normal
     * reconnect sequence instead of waiting for the keepalive interval.
     */
    suspend fun revalidate() {
        val (stream, transport) = stateMutex.withLock {
            if (phase != Phase.ACTIVE) return
            liveStream to currentTransport
        }
        if (stream == null || transport == null) return
        try {
            mutableLatencyUpdates.tryEmit(measureLatency(transport))
            noteConnectionActivity()
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: Throwable) {
            keepaliveDidFail(asTransportFailure(failure), stream)
        }
    }

    /** Deliberate background teardown: ends channel and SSH connection. */
    suspend fun suspendSession() = lifecycleMutex.withLock { deactivate(emitStatus = true) }

    /** Terminal teardown. The session cannot be resumed after this. */
    suspend fun end() = lifecycleMutex.withLock {
        val shouldFinish = stateMutex.withLock {
            if (phase == Phase.ENDED) false else {
                phase = Phase.ENDED
                true
            }
        }
        if (!shouldFinish) return@withLock
        windDown()
        yieldUpdate(EventsSessionUpdate.Status(EventsSessionStatus.Ended))
        updatesRelay.finish()
        scope.cancel()
    }

    /**
     * Replaces subscriptions. A live channel ends explicitly and re-subscribes
     * immediately on the same transport; its ensuing Connected update requires
     * the ordinary snapshot re-sync. Pane entries still disappear on every
     * disconnect and must be reinstalled after each Connected update.
     */
    suspend fun updateSubscriptions(newSubscriptions: List<EventSubscription>) {
        val stream = stateMutex.withLock {
            if (subscriptions == newSubscriptions) return
            subscriptions = newSubscriptions
            if (phase == Phase.ACTIVE && liveStream != null) {
                resubscribeRequested = true
                liveStream
            } else {
                null
            }
        }
        stream?.end()
    }

    suspend fun <T> withTransport(operation: suspend (Transport) -> T): T {
        val transport = stateMutex.withLock {
            currentTransport ?: throw TransportError.SshUnreachable("The Host is not connected.")
        }
        val value = operation(transport)
        noteConnectionActivity()
        return value
    }

    /**
     * Runs one terminal lifetime with exclusive access to the Host terminal
     * channel. The permit spans explicit terminal teardown.
     */
    suspend fun <T> withTerminalTransport(operation: suspend (Transport) -> T): T =
        terminalMutex.withLock { withTransport(operation) }

    /** A test/diagnostic count of updates shed by the bounded buffer. */
    val droppedUpdateCount: Long get() = updatesRelay.droppedCount

    private suspend fun deactivate(emitStatus: Boolean) {
        val shouldDeactivate = stateMutex.withLock {
            if (phase != Phase.ACTIVE) false else {
                phase = Phase.SUSPENDED
                true
            }
        }
        if (!shouldDeactivate) return
        windDown()
        if (emitStatus) yieldUpdate(EventsSessionUpdate.Status(EventsSessionStatus.Suspended))
    }
    private suspend fun activateIfSuspended() {
        val generation = stateMutex.withLock {
            if (phase != Phase.SUSPENDED) return
            phase = Phase.ACTIVE
            activationGeneration++
            activationGeneration
        }
        stateMutex.withLock {
            runJob = scope.launch { run(generation) }
        }
    }

    private suspend fun run(generation: ULong) {
        var attempt = 0
        while (activationIsCurrent(generation)) {
            val stream = try {
                val transport = ensureTransport(generation)
                val requested = stateMutex.withLock { subscriptions }
                transport.subscribeToEvents(requested)
            } catch (failure: Throwable) {
                val transportFailure = asTransportFailure(failure)
                if (
                    transportFailure == TransportError.TimedOut ||
                    transportFailure is TransportError.StreamLocalOpenFailed
                ) {
                    stateMutex.withLock { transportSuspect = true }
                }
                if (namesMissingPane(transportFailure) && dropPaneSubscriptions()) continue
                if (!retryableForSession(transportFailure)) {
                    yieldUpdate(EventsSessionUpdate.Status(EventsSessionStatus.Failed(transportFailure)))
                    return
                }
                dropPaneSubscriptions()
                attempt++
                reconnectAfter(attempt, transportFailure, generation)
                continue
            }

            if (!activationIsCurrent(generation)) {
                stream.end()
                return
            }
            stateMutex.withLock {
                liveStream = stream
                hasEstablishedEventsStream = true
                pendingKeepaliveFailure = null
            }
            attempt = 0
            yieldUpdate(EventsSessionUpdate.Status(EventsSessionStatus.Connected))
            startKeepalive(stream)

            var streamFailure: TransportError? = null
            try {
                stream.events.collect { event ->
                    if (activationIsCurrent(generation)) {
                        noteConnectionActivity()
                        yieldUpdate(EventsSessionUpdate.Event(event))
                    }
                }
            } catch (failure: Throwable) {
                if (failure !is CancellationException) streamFailure = asTransportFailure(failure)
            }

            val deliberateResubscribe: Boolean
            val keepaliveFailure: TransportError?
            stateMutex.withLock {
                if (liveStream === stream) {
                    stopKeepaliveLocked()
                    liveStream = null
                }
                deliberateResubscribe = resubscribeRequested
                resubscribeRequested = false
                keepaliveFailure = pendingKeepaliveFailure
                pendingKeepaliveFailure = null
            }
            if (!activationIsCurrent(generation)) return
            if (deliberateResubscribe) continue

            val failure = keepaliveFailure ?: streamFailure
                ?: TransportError.ChannelFailed("events stream ended unexpectedly")
            if (!retryableForSession(failure)) {
                yieldUpdate(EventsSessionUpdate.Status(EventsSessionStatus.Failed(failure)))
                return
            }
            dropPaneSubscriptions()
            attempt++
            reconnectAfter(attempt, failure, generation)
        }
    }

    /**
     * Discards pane-scoped entries while retaining globals. herdr rejects a
     * whole `events.subscribe` if one pane has exited; carrying snapshot-derived
     * entries over a reconnect would retry that doomed set forever.
     */
    private suspend fun dropPaneSubscriptions(): Boolean = stateMutex.withLock {
        val globals = subscriptions.filterIsInstance<EventSubscription.Global>()
        if (globals.size == subscriptions.size) false else {
            subscriptions = globals
            true
        }
    }

    private fun namesMissingPane(failure: TransportError): Boolean =
        failure is TransportError.ApiRejected && failure.code == "pane_not_found"

    private suspend fun ensureTransport(generation: ULong): Transport {
        if (!activationIsCurrent(generation)) throw TransportError.Cancelled
        val current = stateMutex.withLock { currentTransport to transportSuspect }
        if (current.first != null && !current.second && current.first!!.isConnected()) {
            return current.first!!
        }
        current.first?.let {
            stateMutex.withLock { if (currentTransport === it) currentTransport = null }
            try {
                it.close()
            } catch (_: Throwable) {
                // A replacement connection cannot use an old transport either way.
            }
        }

        val fresh = connect()
        try {
            if (!activationIsCurrent(generation)) throw TransportError.Cancelled
            mutableLatencyUpdates.tryEmit(measureLatency(fresh))
            if (!activationIsCurrent(generation)) throw TransportError.Cancelled
        } catch (failure: Throwable) {
            try {
                fresh.close()
            } catch (_: Throwable) {
                // The connection is already rejected; preserve the original failure.
            }
            throw failure
        }
        stateMutex.withLock {
            transportSuspect = false
            currentTransport = fresh
            if (hasEstablishedTransport) transportGeneration++ else hasEstablishedTransport = true
        }
        noteConnectionActivity()
        return fresh
    }

    private suspend fun reconnectAfter(attempt: Int, failure: TransportError, generation: ULong) {
        val backoffDelay = reconnectPolicy.delayBeforeAttempt(attempt)
        yieldUpdate(
            EventsSessionUpdate.Status(
                EventsSessionStatus.Reconnecting(attempt, backoffDelay, failure),
            ),
        )
        delay(backoffDelay)
        currentCoroutineContext().ensureActive()
        if (!activationIsCurrent(generation)) return
    }

    private data class WindDownResources(
        val run: Job?,
        val keepalive: Job?,
        val stream: HerdrEventStream?,
        val transport: Transport?,
    )

    private suspend fun windDown() {
        val resources = stateMutex.withLock {
            WindDownResources(runJob, keepaliveJob, liveStream, currentTransport).also {
                runJob = null
                keepaliveJob = null
                liveStream = null
                currentTransport = null
                transportSuspect = false
                pendingKeepaliveFailure = null
                resubscribeRequested = false
                lastConnectionActivityNanos = null
            }
        }
        resources.run?.cancel()
        resources.keepalive?.cancel()
        try {
            resources.transport?.close()
        } catch (_: Throwable) {
            // Explicit teardown is terminal even when the remote close races a disconnect.
        }
        resources.stream?.end()
        // Wait for any attach operation before a replacement transport can install.
        terminalMutex.withLock { }
        dropPaneSubscriptions()
    }

    private suspend fun startKeepalive(stream: HerdrEventStream) {
        val policy = keepalive ?: return
        val job = scope.launch {
            while (true) {
                delay(policy.interval)
                currentCoroutineContext().ensureActive()
                if (!connectionIsIdle(policy.interval)) continue
                val transport = stateMutex.withLock { currentTransport } ?: return@launch
                try {
                    mutableLatencyUpdates.tryEmit(measureLatency(transport))
                    noteConnectionActivity()
                } catch (failure: CancellationException) {
                    return@launch
                } catch (failure: Throwable) {
                    keepaliveDidFail(asTransportFailure(failure), stream)
                    return@launch
                }
            }
        }
        stateMutex.withLock {
            stopKeepaliveLocked()
            keepaliveJob = job
        }
    }

    private fun stopKeepaliveLocked() {
        keepaliveJob?.cancel()
        keepaliveJob = null
    }

    private suspend fun keepaliveDidFail(failure: TransportError, stream: HerdrEventStream) {
        val shouldEnd = stateMutex.withLock {
            if (phase != Phase.ACTIVE || liveStream !== stream) false else {
                transportSuspect = true
                pendingKeepaliveFailure = failure
                true
            }
        }
        if (shouldEnd) stream.end()
    }

    private suspend fun activationIsCurrent(generation: ULong): Boolean = stateMutex.withLock {
        phase == Phase.ACTIVE && activationGeneration == generation
    }

    private suspend fun measureLatency(transport: Transport): Duration {
        val started = System.nanoTime()
        transport.ping()
        return (System.nanoTime() - started).nanoseconds
    }

    private suspend fun noteConnectionActivity() {
        stateMutex.withLock { lastConnectionActivityNanos = System.nanoTime() }
    }

    private suspend fun connectionIsIdle(interval: Duration): Boolean = stateMutex.withLock {
        val last = lastConnectionActivityNanos ?: return@withLock true
        System.nanoTime() - last >= interval.inWholeNanoseconds
    }

    /**
     * A first stream-local failure is still terminal: it can mean disabled
     * forwarding or a wrong Host setup. Once this Host has already delivered
     * events, the same failure after a dropped SSH connection is indistinct
     * from herdr briefly restarting, so use normal bounded reconnect backoff.
     */
    private suspend fun retryableForSession(failure: TransportError): Boolean =
        failure.isRetryable || (
            failure is TransportError.StreamLocalOpenFailed &&
                stateMutex.withLock { hasEstablishedEventsStream }
            )

    private fun yieldUpdate(update: EventsSessionUpdate) = updatesRelay.yield(update)

    private fun asTransportFailure(failure: Throwable): TransportError = when (failure) {
        is TransportError -> failure
        is HerdrApiError -> TransportError.ApiRejected(failure.code, failure.serverMessage)
        is CancellationException -> TransportError.Cancelled
        else -> TransportError.ChannelFailed(failure.toString())
    }
}

/**
 * One-consumer bounded update relay. It owns overflow accounting because stock
 * DROP_OLDEST flows drop silently; every shed item becomes a local drop marker.
 */
private class EventsUpdateRelay(private val limit: Int) {
    private val lock = ReentrantLock()
    private val queue = ArrayDeque<EventsSessionUpdate>()
    private var waiter: kotlinx.coroutines.CompletableDeferred<Unit>? = null
    private var finished = false
    private var consumer: Job? = null
    var droppedCount: Long = 0
        private set

    val flow: Flow<EventsSessionUpdate> = flow {
        val reader = currentCoroutineContext()[Job] ?: error("Events flow requires a Job")
        claim(reader)
        while (true) {
            val next = next(reader) ?: break
            emit(next)
        }
    }

    fun yield(update: EventsSessionUpdate) {
        val wake = lock.withLock {
            if (finished) return
            if (update is EventsSessionUpdate.Status &&
                (update.status == EventsSessionStatus.Suspended || update.status == EventsSessionStatus.Ended)
            ) {
                queue.clear()
                queue.addLast(update)
            } else if (queue.size < limit) {
                queue.addLast(update)
            } else {
                queue.removeAt(0)
                droppedCount++
                queue.addLast(update)
                if (queue.size == limit) {
                    queue.removeAt(0)
                    droppedCount++
                }
                queue.addLast(EventsSessionUpdate.Event(HerdrEvent.eventsDropped))
            }
            waiter.also { waiter = null }
        }
        wake?.complete(Unit)
    }

    fun finish() {
        val wake = lock.withLock {
            finished = true
            waiter.also { waiter = null }
        }
        wake?.complete(Unit)
    }

    private fun claim(reader: Job) = lock.withLock {
        check(consumer == null || consumer === reader) { "Events updates support one consumer." }
        consumer = reader
    }

    private suspend fun next(reader: Job): EventsSessionUpdate? {
        while (true) {
            val waiting = lock.withLock {
                check(consumer === reader) { "Events updates are owned by another consumer." }
                queue.removeFirstOrNull()?.let { return it }
                if (finished) return null
                check(waiter == null) { "Events updates have more than one reader." }
                kotlinx.coroutines.CompletableDeferred<Unit>().also { waiter = it }
            }
            try {
                waiting.await()
            } catch (failure: CancellationException) {
                lock.withLock { if (waiter === waiting) waiter = null }
                throw failure
            }
        }
    }
}

