package dev.bybee.heeler.core.transport

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Separates OpenSSH forwarding and session admission while enforcing one
 * finite ceiling over every live SSH channel on a Host connection.
 *
 * Session categories leave headroom under sshd's default `MaxSessions` of 10
 * (ADR 0011). That server-side limit is the real binding constraint for exec,
 * PTY, and SFTP channels, and the app cannot observe it: an abandoned channel
 * teardown still releases the app admission lease unconditionally, while the
 * server session slot can remain occupied. App counters and `isConnected` may
 * therefore still look available after the server has spent the slot; they
 * cannot promise MaxSessions safety.
 */
class SshChannelAdmission(
    private val limits: Limits = Limits.PRODUCTION,
) {
    enum class ChannelClass {
        ORDINARY_FORWARDING,
        EVENTS,
        ORDINARY_SESSION,
        ATTACH,
    }

    data class Limits(
        val ordinaryForwarding: Int,
        val events: Int,
        val ordinarySession: Int,
        val attach: Int,
        val connection: Int,
    ) {
        init {
            require(ordinaryForwarding > 0)
            require(events > 0)
            require(ordinarySession > 0)
            require(attach > 0)
            require(connection > 0)
        }

        companion object {
            /**
             * Production budgets. `connection` restates the sum of the four
             * category budgets (8+1+8+1), so the connection-level guard does
             * not bind under these categories. Per-category budgets are the
             * admission limits; do not treat 18 as a tighter guarantee than
             * them or than server `MaxSessions`.
             */
            val PRODUCTION = Limits(
                ordinaryForwarding = 8,
                events = 1,
                ordinarySession = 8,
                attach = 1,
                connection = 18,
            )
        }
    }

    data class Snapshot(
        val ordinaryForwarding: Int,
        val events: Int,
        val ordinarySession: Int,
        val attach: Int,
        val connection: Int,
    )

    private data class Waiter(
        val channelClass: ChannelClass,
        val signal: CompletableDeferred<Unit>,
        var admitted: Boolean = false,
    )

    private val mutex = Mutex()
    private var counts = Snapshot(0, 0, 0, 0, 0)
    private val waiters = ArrayDeque<Waiter>()

    suspend fun <T> withChannel(
        channelClass: ChannelClass,
        operation: suspend () -> T,
    ): T {
        val lease = acquire(channelClass)
        return try {
            operation()
        } finally {
            lease.release()
        }
    }

    suspend fun acquire(channelClass: ChannelClass): SshChannelAdmissionLease {
        val waiter = mutex.withLock {
            if (canAcquire(channelClass)) {
                increment(channelClass)
                null
            } else {
                Waiter(channelClass, CompletableDeferred<Unit>()).also(waiters::addLast)
            }
        }
        if (waiter != null) {
            try {
                waiter.signal.await()
            } catch (failure: CancellationException) {
                val releaseLease = mutex.withLock {
                    if (waiters.remove(waiter)) {
                        false
                    } else {
                        waiter.admitted
                    }
                }
                if (releaseLease) release(channelClass)
                throw failure
            }
        }
        return SshChannelAdmissionLease(this, channelClass)
    }

    suspend fun snapshot(): Snapshot = mutex.withLock { counts }

    private suspend fun release(channelClass: ChannelClass) {
        mutex.withLock {
            decrement(channelClass)
            resumeEligibleWaiters()
        }
    }

    private fun resumeEligibleWaiters() {
        for (waiter in waiters.toList()) {
            if (!canAcquire(waiter.channelClass)) continue
            waiters.remove(waiter)
            increment(waiter.channelClass)
            waiter.admitted = true
            waiter.signal.complete(Unit)
        }
    }

    private fun canAcquire(channelClass: ChannelClass): Boolean {
        if (counts.connection >= limits.connection) return false
        return when (channelClass) {
            ChannelClass.ORDINARY_FORWARDING -> counts.ordinaryForwarding < limits.ordinaryForwarding
            ChannelClass.EVENTS -> counts.events < limits.events
            ChannelClass.ORDINARY_SESSION -> counts.ordinarySession < limits.ordinarySession
            ChannelClass.ATTACH -> counts.attach < limits.attach
        }
    }

    private fun increment(channelClass: ChannelClass) {
        counts = counts.copy(
            ordinaryForwarding = counts.ordinaryForwarding +
                if (channelClass == ChannelClass.ORDINARY_FORWARDING) 1 else 0,
            events = counts.events + if (channelClass == ChannelClass.EVENTS) 1 else 0,
            ordinarySession = counts.ordinarySession +
                if (channelClass == ChannelClass.ORDINARY_SESSION) 1 else 0,
            attach = counts.attach + if (channelClass == ChannelClass.ATTACH) 1 else 0,
            connection = counts.connection + 1,
        )
    }

    private fun decrement(channelClass: ChannelClass) {
        check(counts.connection > 0)
        counts = counts.copy(
            ordinaryForwarding = counts.ordinaryForwarding -
                if (channelClass == ChannelClass.ORDINARY_FORWARDING) 1 else 0,
            events = counts.events - if (channelClass == ChannelClass.EVENTS) 1 else 0,
            ordinarySession = counts.ordinarySession -
                if (channelClass == ChannelClass.ORDINARY_SESSION) 1 else 0,
            attach = counts.attach - if (channelClass == ChannelClass.ATTACH) 1 else 0,
            connection = counts.connection - 1,
        )
    }

    class SshChannelAdmissionLease internal constructor(
        private val admission: SshChannelAdmission,
        private val channelClass: ChannelClass,
    ) {
        private val released = AtomicBoolean(false)

        suspend fun release() {
            if (released.compareAndSet(false, true)) admission.release(channelClass)
        }
    }
}
