package dev.bybee.heeler.core.ssh

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * The only Kotlin owner of a libssh2 session handle.
 *
 * Each instance owns one dedicated thread because libssh2 sessions are not
 * thread-safe. A native operation is deliberately one nonblocking libssh2
 * call: on EAGAIN the calling coroutine returns to the dispatcher queue after
 * a short poll. This lets an active reader and writer on different channels
 * alternate instead of allowing either to monopolize the session.
 */
internal class SshSessionDriver private constructor(
    private var session: Long,
    private val dispatcher: CoroutineDispatcher,
    private val closeDispatcher: () -> Unit,
) {
    private data class NativeResult<T>(
        val value: T,
        val errno: Int,
        val error: String,
    )

    private var closed = false

    companion object {
        private const val POLL_TIMEOUT_MS = 25
        private const val CLOSE_POLL_ATTEMPTS = 80
        private val nextDriverId = AtomicLong(1)

        suspend fun create(): SshSessionDriver {
            val executor = Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "HeelerSsh-${nextDriverId.getAndIncrement()}").apply {
                    isDaemon = true
                }
            }
            val dispatcher = executor.asCoroutineDispatcher()
            val driver = SshSessionDriver(0, dispatcher, dispatcher::close)
            val handle = withContext(dispatcher) { NativeSsh.sessionNew() }
            if (handle == 0L) {
                dispatcher.close()
                throw SshException.Protocol("libssh2 session allocation failed")
            }
            driver.session = handle
            return driver
        }
    }

    private suspend fun <T> nativeCall(block: () -> T): NativeResult<T> {
        currentCoroutineContext().ensureActive()
        return withContext(dispatcher) {
            if (closed || session == 0L) throw SshException.Closed()
            val value = block()
            NativeResult(
                value = value,
                errno = NativeSsh.lastErrno(session),
                error = NativeSsh.lastError(session),
            )
        }
    }

    /**
     * Cleanup retains native access after [closed] rejects new public work.
     * This is what lets disconnect retry its nonblocking SSH_MSG_DISCONNECT.
     */
    private suspend fun <T> teardownCall(block: () -> T): NativeResult<T> {
        currentCoroutineContext().ensureActive()
        return withContext(dispatcher) {
            if (session == 0L) throw SshException.Closed()
            val value = block()
            NativeResult(
                value = value,
                errno = NativeSsh.lastErrno(session),
                error = NativeSsh.lastError(session),
            )
        }
    }

    private fun failure(operation: String, result: NativeResult<*>): Nothing {
        throw SshException.NativeFailure(
            operation = operation,
            code = if (result.value is Int && result.value < 0) result.value else result.errno,
            detail = result.error.ifBlank { "native operation returned ${result.value}" },
        )
    }

    private suspend fun awaitProgress(operation: String) {
        val result = nativeCall { NativeSsh.poll(session, POLL_TIMEOUT_MS) }
        if (result.value < 0) failure("$operation poll", result)
        // Yield even after readiness. A single readiness notification can be
        // consumed by another channel; fairness matters more than spinning.
        yield()
    }

    private suspend fun retryUnit(operation: String, block: () -> Int) {
        while (true) {
            val result = nativeCall(block)
            when {
                result.value == 0 -> return
                result.value == NativeSsh.AGAIN || result.errno == NativeSsh.AGAIN -> awaitProgress(operation)
                else -> failure(operation, result)
            }
        }
    }

    private suspend fun retryHandle(operation: String, block: () -> Long): Long {
        while (true) {
            val result = nativeCall(block)
            if (result.value != 0L) return result.value
            if (result.errno == NativeSsh.AGAIN) {
                awaitProgress(operation)
            } else {
                failure(operation, result)
            }
        }
    }

    private suspend fun retryWrite(operation: String, data: ByteArray, writer: (Int, Int) -> Int) {
        var offset = 0
        while (offset < data.size) {
            val remaining = data.size - offset
            val result = nativeCall { writer(offset, remaining) }
            when {
                result.value > 0 -> {
                    offset += result.value
                    yield()
                }
                result.value == 0 || result.value == NativeSsh.AGAIN || result.errno == NativeSsh.AGAIN -> {
                    awaitProgress(operation)
                }
                else -> failure(operation, result)
            }
        }
    }

    private suspend fun read(
        operation: String,
        channel: Long,
        maximumBytes: Int,
        readNative: (ByteArray) -> Int,
    ): ByteArray? {
        require(maximumBytes > 0) { "maximumBytes must be positive" }
        val buffer = ByteArray(maximumBytes)
        while (true) {
            val result = nativeCall { readNative(buffer) }
            when {
                result.value > 0 -> return buffer.copyOf(result.value)
                result.value == NativeSsh.AGAIN || result.errno == NativeSsh.AGAIN -> awaitProgress(operation)
                result.value == 0 -> {
                    val eof = nativeCall { NativeSsh.channelEof(session, channel) }.value
                    if (eof) return null
                    awaitProgress(operation)
                }
                else -> failure(operation, result)
            }
        }
    }

    suspend fun connectSocket(host: String, port: Int, timeoutMs: Int) {
        require(host.isNotBlank()) { "SSH host must not be blank" }
        require(port in 1..65535) { "SSH port must be in 1..65535" }
        require(timeoutMs >= 0) { "connect timeout must not be negative" }
        retryUnit("connect socket") { NativeSsh.connectSocket(session, host, port, timeoutMs) }
    }

    suspend fun attachSocketFd(fd: Int) {
        require(fd >= 0) { "forwarded socket descriptor must be nonnegative" }
        retryUnit("attach forwarded socket") { NativeSsh.connectSocketFd(session, fd) }
    }

    suspend fun handshake() {
        retryUnit("SSH handshake") { NativeSsh.handshake(session) }
    }

    suspend fun hostKey(): SshHostKey {
        val result = nativeCall {
            val raw = NativeSsh.hostKey(session)
            val algorithm = NativeSsh.hostKeyType(session)
            raw to algorithm
        }
        val (raw, algorithm) = result.value
        if (raw == null || algorithm.isNullOrBlank()) {
            throw SshException.Protocol("SSH handshake completed without a server host key")
        }
        return SshHostKey(algorithm = algorithm, rawKey = raw)
    }

    suspend fun authenticate(username: String, authentication: SshAuthentication) {
        require(username.isNotBlank()) { "SSH username must not be blank" }
        when (authentication) {
            is SshAuthentication.Password -> {
                require(authentication.value.isNotEmpty()) { "SSH password must not be empty" }
                // JNI takes a String, but the connection never retains it.
                val password = authentication.value.concatToString()
                retryUnit("password authentication") {
                    NativeSsh.userauthPassword(session, username, password)
                }
            }

            is SshAuthentication.PublicKey -> {
                require(authentication.privateKeyPem.isNotEmpty()) { "private key must not be empty" }
                val passphrase = authentication.passphrase.concatToString()
                retryUnit("public-key authentication") {
                    NativeSsh.userauthPublicKeyFromMemory(
                        session = session,
                        username = username,
                        publicKeyOpenSsh = authentication.publicKeyOpenSsh,
                        privateKeyPem = authentication.privateKeyPem,
                        passphrase = passphrase,
                    )
                }
            }
        }
        if (!nativeCall { NativeSsh.isAuthenticated(session) }.value) {
            throw SshException.Protocol("native authentication completed without an authenticated session")
        }
    }

    suspend fun openStreamLocal(socketPath: String): Long {
        require(socketPath.startsWith('/')) { "streamlocal socket path must be absolute" }
        return retryHandle("open streamlocal channel") { NativeSsh.channelOpenStreamLocal(session, socketPath) }
    }

    suspend fun openExec(command: String, pty: PtyRequest?): Long {
        require(command.isNotBlank()) { "exec command must not be blank" }
        val channel = retryHandle("open exec channel") { NativeSsh.channelOpenSession(session) }
        try {
            if (pty != null) {
                retryUnit("request exec PTY") {
                    NativeSsh.channelRequestPty(session, channel, pty.term, pty.columns, pty.rows)
                }
            }
            retryUnit("start exec") { NativeSsh.channelExec(session, channel, command) }
            return channel
        } catch (error: Throwable) {
            try {
                disposeChannel(channel, sendEof = false)
            } catch (_: Throwable) {
                // Preserve the command/PTY failure; cleanup remains best effort.
            }
            throw error
        }
    }

    suspend fun openDirectTcpIp(host: String, port: Int): Long {
        require(host.isNotBlank()) { "jump-host target must not be blank" }
        require(port in 1..65535) { "jump-host target port must be in 1..65535" }
        return retryHandle("open direct TCP channel") { NativeSsh.channelOpenDirectTcpIp(session, host, port) }
    }

    suspend fun createSocketBridge(channel: Long): Int {
        val result = nativeCall { NativeSsh.channelCreateSocketBridge(session, channel) }
        if (result.value >= 0) return result.value
        failure("create jump-host socket bridge", result)
    }

    suspend fun pumpSocketBridge(channel: Long): Int {
        val result = nativeCall { NativeSsh.channelPumpSocketBridge(session, channel) }
        if (result.value >= 0) return result.value
        failure("pump jump-host socket bridge", result)
    }

    suspend fun readChannel(channel: Long, maximumBytes: Int): ByteArray? =
        read("channel read", channel, maximumBytes) { NativeSsh.channelRead(session, channel, it) }

    suspend fun readChannelStderr(channel: Long, maximumBytes: Int): ByteArray? =
        read("channel stderr read", channel, maximumBytes) { NativeSsh.channelReadStderr(session, channel, it) }

    suspend fun writeChannel(channel: Long, data: ByteArray) {
        if (data.isEmpty()) return
        retryWrite("channel write", data) { offset, length ->
            NativeSsh.channelWrite(session, channel, data, offset, length)
        }
    }

    suspend fun resizePty(channel: Long, columns: Int, rows: Int) {
        require(columns > 0 && rows > 0) { "PTY dimensions must be positive" }
        retryUnit("PTY resize") { NativeSsh.channelResizePty(session, channel, columns, rows) }
    }

    suspend fun channelEof(channel: Long): Boolean = nativeCall {
        NativeSsh.channelEof(session, channel)
    }.value

    private suspend fun awaitTeardownProgress(operation: String) {
        val result = teardownCall { NativeSsh.poll(session, POLL_TIMEOUT_MS) }
        if (result.value < 0) failure("$operation poll", result)
        yield()
    }

    private suspend fun retryTeardown(operation: String, block: () -> Int): SshException? {
        repeat(CLOSE_POLL_ATTEMPTS) {
            val result = teardownCall(block)
            when {
                result.value == 0 -> return null
                result.value == NativeSsh.AGAIN || result.errno == NativeSsh.AGAIN ->
                    awaitTeardownProgress(operation)
                else -> return SshException.NativeFailure(
                    operation,
                    if (result.value < 0) result.value else result.errno,
                    result.error.ifBlank { "native operation returned ${result.value}" },
                )
            }
        }
        return SshException.TimedOut(operation, (CLOSE_POLL_ATTEMPTS * POLL_TIMEOUT_MS).toLong())
    }

    /** Closes and frees a channel even if a best-effort graceful close fails. */
    suspend fun disposeChannel(channel: Long, sendEof: Boolean) {
        var closeFailure: Throwable? = null
        withContext(NonCancellable) {
            if (!closed) {
                if (sendEof) {
                    closeFailure = retryTeardown("channel EOF") {
                        NativeSsh.channelSendEof(session, channel)
                    }
                }
                val channelCloseFailure = retryTeardown("channel close") {
                    NativeSsh.channelClose(session, channel)
                }
                if (closeFailure == null) closeFailure = channelCloseFailure
                withContext(dispatcher) {
                    if (!closed && session != 0L) NativeSsh.channelFree(session, channel)
                }
            }
        }
        closeFailure?.let { throw it }
    }

    suspend fun closeChannelForExitStatus(channel: Long): Int? {
        if (!channelEof(channel)) return null
        var status = -1
        var closeFailure: Throwable? = null
        withContext(NonCancellable) {
            closeFailure = retryTeardown("channel close") {
                NativeSsh.channelClose(session, channel)
            }
            if (closeFailure == null) {
                status = nativeCall { NativeSsh.channelExitStatus(session, channel) }.value
            }
            withContext(dispatcher) {
                if (!closed && session != 0L) NativeSsh.channelFree(session, channel)
            }
        }
        closeFailure?.let { throw it }
        return status.takeIf { it >= 0 }
    }

    suspend fun openSftp(): Long = retryHandle("SFTP init") { NativeSsh.sftpInit(session) }

    suspend fun openSftpFile(sftp: Long, path: String, flags: Int, mode: Int): Long {
        require(path.isNotBlank()) { "SFTP path must not be blank" }
        return retryHandle("SFTP open") { NativeSsh.sftpOpen(session, sftp, path, flags, mode) }
    }

    suspend fun readSftpFile(file: Long, maximumBytes: Int): ByteArray? {
        require(maximumBytes > 0) { "maximumBytes must be positive" }
        val buffer = ByteArray(maximumBytes)
        while (true) {
            val result = nativeCall { NativeSsh.sftpRead(session, file, buffer) }
            when {
                result.value > 0 -> return buffer.copyOf(result.value)
                result.value == 0 -> return null
                result.value == NativeSsh.AGAIN || result.errno == NativeSsh.AGAIN -> awaitProgress("SFTP read")
                else -> failure("SFTP read", result)
            }
        }
    }

    suspend fun writeSftpFile(file: Long, data: ByteArray) {
        if (data.isEmpty()) return
        retryWrite("SFTP write", data) { offset, length ->
            NativeSsh.sftpWrite(session, file, data, offset, length)
        }
    }

    suspend fun closeSftpFile(file: Long) {
        val failure = withContext(NonCancellable) {
            retryTeardown("SFTP file close") { NativeSsh.sftpCloseHandle(session, file) }
        }
        failure?.let { throw it }
    }

    suspend fun renameSftp(sftp: Long, source: String, destination: String) {
        require(source.isNotBlank() && destination.isNotBlank()) { "SFTP paths must not be blank" }
        retryUnit("SFTP rename") { NativeSsh.sftpRename(session, sftp, source, destination) }
    }

    suspend fun unlinkSftp(sftp: Long, path: String) {
        require(path.isNotBlank()) { "SFTP path must not be blank" }
        retryUnit("SFTP unlink") { NativeSsh.sftpUnlink(session, sftp, path) }
    }

    suspend fun mkdirSftp(sftp: Long, path: String, mode: Int) {
        require(path.isNotBlank()) { "SFTP path must not be blank" }
        retryUnit("SFTP mkdir") { NativeSsh.sftpMkdir(session, sftp, path, mode) }
    }

    suspend fun closeSftp(sftp: Long) {
        val failure = withContext(NonCancellable) {
            retryTeardown("SFTP shutdown") { NativeSsh.sftpShutdown(session, sftp) }
        }
        failure?.let { throw it }
    }

    suspend fun disconnect() {
        var handleToFree = 0L
        withContext(NonCancellable) {
            withContext(dispatcher) {
                if (!closed && session != 0L) {
                    closed = true
                    handleToFree = session
                }
            }
            if (handleToFree != 0L) {
                retryTeardown("SSH disconnect") {
                    NativeSsh.sessionDisconnect(session, "Heeler disconnect")
                }
                withContext(dispatcher) {
                    if (session == handleToFree) {
                        session = 0L
                        NativeSsh.sessionFree(handleToFree)
                    }
                }
            }
        }
        closeDispatcher()
    }
}
