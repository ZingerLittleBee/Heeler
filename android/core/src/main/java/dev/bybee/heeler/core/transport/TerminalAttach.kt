package dev.bybee.heeler.core.transport

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.time.Duration.Companion.milliseconds

/** One Attach request: target Pane, takeover flag, and initial PTY geometry. */
data class TerminalAttachRequest(
    val target: String,
    val takeover: Boolean = false,
    val cols: Int,
    val rows: Int,
) {
    init {
        require(cols > 0) { "Terminal columns must be positive." }
        require(rows > 0) { "Terminal rows must be positive." }
    }
}

/**
 * The handshake that separates an attach channel's pre-attach noise from the
 * attach session itself.
 *
 * OpenSSH still hands every exec request to the remote account shell as
 * `shell -c command`, even when Heeler requests a PTY and an exec together.
 * The account shell or SSH session can emit startup or rc chatter before this
 * marker and `exec herdr agent attach`. None of that belongs on the terminal.
 * The marker is real control bytes: literal `\\033` chatter cannot open the
 * gate, and APC is ignored by terminals so a stray copy is harmless.
 */
object AttachBootstrapHandshake {
    val marker: ByteArray = byteArrayOf(
        0x1b,
        '_'.code.toByte(),
        *"heeler-attach".encodeToByteArray(),
        0x1b,
        '\\'.code.toByte(),
    )

    /** [marker] as a portable, octal-only `printf` format. */
    const val MARKER_PRINTF_FORMAT = "\\033_heeler-attach\\033\\134"
}

/** Holds attach output back until the bootstrap handshake arrives. */
class AttachBootstrapGate {
    /** A ceiling for a channel that never handshakes; retain the diagnostic tail. */
    companion object {
        const val MAXIMUM_WITHHELD_BYTES = 8 * 1024
    }

    private var isOpen = false
    private var withheld = ByteArray(0)

    /** The bytes the terminal should paint: nothing until the marker arrives. */
    fun admit(bytes: ByteArray): ByteArray {
        if (isOpen) return bytes
        withheld += bytes
        val markerOffset = withheld.indexOf(AttachBootstrapHandshake.marker)
        if (markerOffset < 0) {
            if (withheld.size > MAXIMUM_WITHHELD_BYTES) {
                withheld = withheld.copyOfRange(withheld.size - MAXIMUM_WITHHELD_BYTES, withheld.size)
            }
            return ByteArray(0)
        }
        isOpen = true
        val sessionOffset = markerOffset + AttachBootstrapHandshake.marker.size
        return withheld.copyOfRange(sessionOffset, withheld.size).also { withheld = ByteArray(0) }
    }

    /** The withheld startup diagnostic when the channel ends before it handshakes. */
    fun flush(): ByteArray {
        if (isOpen) return ByteArray(0)
        return withheld.also { withheld = ByteArray(0) }
    }
}

/** Input riding down a live Attach session. */
sealed interface TerminalAttachInput {
    data class Keystrokes(val bytes: ByteArray) : TerminalAttachInput
    data class Scroll(val bytes: ByteArray) : TerminalAttachInput
    data class Resize(val cols: Int, val rows: Int) : TerminalAttachInput
}

/**
 * The live PTY's mixed-reliability input queue.
 *
 * Keystrokes and resizes are reliable and ordered. Touch scrolling is an
 * ephemeral viewport intent: keeping every momentum row under backpressure
 * only makes stale scrolling delay later keyboard input. Scroll rows are
 * coalesced, bounded, and discarded as soon as a reliable key arrives. The
 * writer asks for one item only after the previous SSH write completes, so
 * priority is decided at the last useful moment.
 */
class TerminalAttachInputQueue {
    companion object {
        const val MAXIMUM_PENDING_SCROLL_ROWS = 12
        const val MAXIMUM_SCROLL_ROWS_PER_WRITE = 3
        val SCROLL_PACING_INTERVAL = 33.milliseconds
    }

    private data class PendingScroll(val sequence: ByteArray, var rows: Int)

    private val lock = ReentrantLock()
    private val reliable = ArrayDeque<TerminalAttachInput>()
    private var pendingScroll: PendingScroll? = null
    private var waiter: CompletableDeferred<Unit>? = null
    private var finished = false

    fun send(keystrokes: ByteArray) {
        if (keystrokes.isEmpty()) return
        // Inputs are accepted asynchronously; retain an owned snapshot.
        enqueueReliable(TerminalAttachInput.Keystrokes(keystrokes.copyOf()), discardPendingScroll = true)
    }

    fun scroll(sequence: ByteArray, rows: Int) {
        if (sequence.isEmpty() || rows <= 0) return
        val wake = lock.withLock {
            if (finished) return
            val existing = pendingScroll
            pendingScroll = if (existing != null && existing.sequence.contentEquals(sequence)) {
                existing.copy(rows = (existing.rows + rows).coerceAtMost(MAXIMUM_PENDING_SCROLL_ROWS))
            } else {
                // A direction change makes previous momentum stale.
                PendingScroll(sequence.copyOf(), rows.coerceAtMost(MAXIMUM_PENDING_SCROLL_ROWS))
            }
            waiter.also { waiter = null }
        }
        wake?.complete(Unit)
    }

    fun resize(cols: Int, rows: Int) {
        if (cols <= 0 || rows <= 0) return
        enqueueReliable(TerminalAttachInput.Resize(cols, rows), discardPendingScroll = false)
    }

    suspend fun next(): TerminalAttachInput? {
        while (true) {
            val waiting = lock.withLock {
                reliable.removeFirstOrNull()?.let { return it }
                pendingScroll?.let { scroll ->
                    val deliveredRows = scroll.rows.coerceAtMost(MAXIMUM_SCROLL_ROWS_PER_WRITE)
                    val remainingRows = scroll.rows - deliveredRows
                    pendingScroll = if (remainingRows == 0) null else scroll.copy(rows = remainingRows)
                    return TerminalAttachInput.Scroll(repeat(scroll.sequence, deliveredRows))
                }
                if (finished) return null
                check(waiter == null) { "Attach input has more than one consumer" }
                CompletableDeferred<Unit>().also { waiter = it }
            }
            try {
                waiting.await()
            } catch (failure: CancellationException) {
                lock.withLock {
                    if (waiter === waiting) waiter = null
                }
                throw failure
            }
        }
    }

    fun finish() {
        val wake = lock.withLock {
            if (finished) return
            finished = true
            // Explicit shutdown drains reliable input already accepted. Only
            // ephemeral scroll momentum is abandoned.
            pendingScroll = null
            waiter.also { waiter = null }
        }
        wake?.complete(Unit)
    }

    /** Drains input until the queue finishes or the writer is cancelled. */
    suspend fun pump(
        write: suspend (ByteArray) -> Unit,
        resize: suspend (cols: Int, rows: Int) -> Unit,
    ) {
        while (true) {
            currentCoroutineContext().ensureActive()
            when (val input = next() ?: return) {
                is TerminalAttachInput.Keystrokes -> write(input.bytes)
                is TerminalAttachInput.Scroll -> {
                    write(input.bytes)
                    delay(SCROLL_PACING_INTERVAL)
                }
                is TerminalAttachInput.Resize -> resize(input.cols, input.rows)
            }
        }
    }

    private fun enqueueReliable(input: TerminalAttachInput, discardPendingScroll: Boolean) {
        val wake = lock.withLock {
            if (finished) return
            if (discardPendingScroll) pendingScroll = null
            if (reliable.isEmpty()) {
                waiter.also { waiter = null } ?: run {
                    reliable.addLast(input)
                    null
                }
            } else {
                reliable.addLast(input)
                null
            }
        }
        wake?.complete(Unit)
    }

    private fun repeat(sequence: ByteArray, count: Int): ByteArray {
        val result = ByteArray(sequence.size * count)
        repeat(count) { index ->
            sequence.copyInto(result, destinationOffset = index * sequence.size)
        }
        return result
    }
}

/**
 * Linearizes explicit Attach shutdown with terminal output delivery.
 *
 * A finished flow can still contain buffered elements. This gate owns the
 * buffer so explicit `end()` discards it, while a clean remote exit drains
 * every accepted byte. The first collecting coroutine owns the output; a
 * second one fails with [TransportError.TerminalChannelAlreadyOpen].
 */
class TerminalAttachOutputGate {
    private sealed interface Completion {
        data object Finished : Completion
        data class Failed(val failure: Throwable) : Completion
    }

    private val lock = ReentrantLock()
    private val buffered = ArrayDeque<ByteArray>()
    private var waiter: CompletableDeferred<Result<ByteArray?>>? = null
    private var completion: Completion? = null
    private var explicitlyEnding = false
    private var consumerCancelled = false
    private var consumer: Job? = null

    fun output(): Flow<ByteArray> = flow {
        val reader = currentCoroutineContext()[Job]
            ?: error("Terminal output requires a coroutine Job")
        claim(reader)
        try {
            while (true) {
                val bytes = next(reader) ?: break
                emit(bytes)
            }
        } catch (failure: CancellationException) {
            cancelConsumer(reader)
            throw failure
        }
    }

    fun beginExplicitEnd() {
        val resume = lock.withLock {
            if (explicitlyEnding) return
            explicitlyEnding = true
            buffered.clear()
            waiter.also { waiter = null }
        }
        resume?.complete(Result.success(null))
    }

    fun yield(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val resume = lock.withLock {
            if (explicitlyEnding || consumerCancelled || completion != null) return
            waiter.also { waiter = null } ?: run {
                buffered.addLast(bytes)
                null
            }
        }
        resume?.complete(Result.success(bytes))
    }

    fun finish(failure: Throwable? = null) {
        val resume = lock.withLock {
            if (completion != null) return
            completion = failure?.let(Completion::Failed) ?: Completion.Finished
            if (buffered.isEmpty()) waiter.also { waiter = null } else null
        }
        if (resume != null) {
            if (failure == null) {
                resume.complete(Result.success(null))
            } else {
                resume.complete(Result.failure(failure))
            }
        }
    }

    private fun claim(reader: Job) = lock.withLock {
        if (consumer != null && consumer !== reader) throw TransportError.TerminalChannelAlreadyOpen
        consumer = reader
    }

    private suspend fun next(reader: Job): ByteArray? {
        val pending = lock.withLock {
            if (consumer !== reader) throw TransportError.TerminalChannelAlreadyOpen
            if (explicitlyEnding || consumerCancelled) return null
            buffered.removeFirstOrNull()?.let { return it }
            when (val ended = completion) {
                Completion.Finished -> return null
                is Completion.Failed -> throw ended.failure
                null -> CompletableDeferred<Result<ByteArray?>>().also { waiter = it }
            }
        }
        return try {
            pending.await().getOrThrow()
        } catch (failure: CancellationException) {
            cancelConsumer(reader)
            throw failure
        }
    }

    private fun cancelConsumer(reader: Job) {
        val resume = lock.withLock {
            if (consumer != null && consumer !== reader || consumerCancelled) return
            consumerCancelled = true
            buffered.clear()
            waiter.also { waiter = null }
        }
        resume?.complete(Result.success(null))
    }
}

/**
 * A live interactive Attach session over its Host's dedicated terminal
 * channel: raw PTY bytes out, keystrokes and window changes in. The byte flow
 * feeds the terminal emulator directly without app-level framing.
 *
 * Ending is explicit: call [end]. Dropping the session or cancelling output
 * collection leaves the SSH channel live until the connection closes.
 */
class TerminalAttachSession internal constructor(
    private val outputFactory: () -> Flow<ByteArray>,
    private val input: TerminalAttachInputQueue,
    private val onEndStarted: () -> Unit = {},
    private val ender: suspend () -> Unit,
) {
    /** Raw PTY output in arrival order. Each access returns a fresh flow view. */
    val output: Flow<ByteArray> get() = outputFactory()

    /** Forwards raw keystroke bytes to the remote PTY. */
    fun send(keystrokes: ByteArray) = input.send(keystrokes)

    /** Coalesces touch-scroll rows so typing never waits behind stale momentum. */
    fun scroll(sequence: ByteArray, rows: Int) = input.scroll(sequence, rows)

    /** Propagates a geometry change to the remote PTY without reattaching. */
    fun resize(cols: Int, rows: Int) = input.resize(cols, rows)

    /** Closes the terminal channel explicitly and waits for teardown. */
    suspend fun end() {
        onEndStarted()
        input.finish()
        ender()
    }
}

private fun ByteArray.indexOf(needle: ByteArray): Int {
    if (needle.isEmpty() || needle.size > size) return -1
    for (offset in 0..size - needle.size) {
        if ((needle.indices).all { this[offset + it] == needle[it] }) return offset
    }
    return -1
}
