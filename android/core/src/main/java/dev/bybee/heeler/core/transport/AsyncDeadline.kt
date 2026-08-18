package dev.bybee.heeler.core.transport

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.time.Duration

/** The deadline won the race against the asynchronous operation. */
sealed class AsyncDeadlineError private constructor() : Exception() {
    data object TimedOut : AsyncDeadlineError()
}

/** Runs one asynchronous operation against a wall-clock deadline. */
object AsyncDeadline {
    /**
     * [operation] is cancelled when the deadline wins. [onTimeout] and
     * [onCancel] run in [NonCancellable] so channel cleanup cannot be lost to
     * the cancellation that requested it.
     */
    suspend fun <T> run(
        timeout: Duration,
        onTimeout: suspend () -> Unit = {},
        onCancel: suspend () -> Unit = {},
        operation: suspend () -> T,
    ): T = try {
        withTimeout(timeout) { operation() }
    } catch (_: TimeoutCancellationException) {
        withContext(NonCancellable) { onTimeout() }
        throw AsyncDeadlineError.TimedOut
    } catch (failure: CancellationException) {
        withContext(NonCancellable) { onCancel() }
        throw failure
    }
}
