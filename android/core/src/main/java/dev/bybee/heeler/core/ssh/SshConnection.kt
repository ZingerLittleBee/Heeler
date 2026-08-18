package dev.bybee.heeler.core.ssh

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Authenticated SSH connection facade used by the transport layer.
 *
 * Host-key verification is deliberately delegated to [verifyHostKey]. The
 * callback receives the original SSH wire blob, so transport can compute its
 * SHA-256 fingerprint and apply its TOFU policy without trusting native code to
 * make a security decision.
 */
class SshConnection private constructor(
    private val driver: SshSessionDriver,
    val hostKey: SshHostKey,
    private val parent: SshConnection? = null,
    private val jumpBridge: JumpSocketBridge? = null,
) {
    private val authenticated = AtomicBoolean(false)
    private val authenticationLock = Mutex()
    private val disconnected = AtomicBoolean(false)

    companion object {
        const val DEFAULT_CONNECT_TIMEOUT_MS: Int = 10_000

        suspend fun connect(
            host: String,
            port: Int = 22,
            timeoutMs: Int = DEFAULT_CONNECT_TIMEOUT_MS,
            verifyHostKey: suspend (SshHostKey) -> Boolean,
        ): SshConnection {
            require(timeoutMs > 0) { "connect timeout must be positive" }
            val driver = SshSessionDriver.create()
            try {
                val hostKey = try {
                    withTimeout(timeoutMs.toLong()) {
                        driver.connectSocket(host, port, timeoutMs)
                        driver.handshake()
                        driver.hostKey()
                    }
                } catch (_: TimeoutCancellationException) {
                    throw SshException.TimedOut("SSH connection", timeoutMs.toLong())
                }
                if (!verifyHostKey(hostKey)) throw SshException.HostKeyRejected(hostKey)
                return SshConnection(driver = driver, hostKey = hostKey)
            } catch (error: Throwable) {
                driver.disconnect()
                throw error
            }
        }

        /**
         * Builds a target SSH connection across an authenticated [jump] host.
         * The target owns the socket bridge and closes the target session,
         * forwarding channel, then jump connection in that order.
         */
        suspend fun connectViaJump(
            jump: SshConnection,
            targetHost: String,
            targetPort: Int = 22,
            timeoutMs: Int = DEFAULT_CONNECT_TIMEOUT_MS,
            verifyHostKey: suspend (SshHostKey) -> Boolean,
        ): SshConnection {
            require(timeoutMs > 0) { "connect timeout must be positive" }
            jump.requireAuthenticated()
            val forwardingChannel = try {
                withTimeout(timeoutMs.toLong()) {
                    jump.driver.openDirectTcpIp(targetHost, targetPort)
                }
            } catch (_: TimeoutCancellationException) {
                throw SshException.TimedOut("open jump-host forwarding channel", timeoutMs.toLong())
            }
            var bridge: JumpSocketBridge? = null
            var targetDriver: SshSessionDriver? = null
            try {
                val hostKey = try {
                    withTimeout(timeoutMs.toLong()) {
                        val childDriver = SshSessionDriver.create()
                        targetDriver = childDriver
                        withContext(NonCancellable) {
                            val childFd = jump.driver.createSocketBridge(forwardingChannel)
                            val newBridge = JumpSocketBridge(jump.driver, forwardingChannel)
                            bridge = newBridge
                            newBridge.start()
                            childDriver.attachSocketFd(childFd)
                        }
                        childDriver.handshake()
                        childDriver.hostKey()
                    }
                } catch (_: TimeoutCancellationException) {
                    throw SshException.TimedOut("jump-host SSH connection", timeoutMs.toLong())
                }
                if (!verifyHostKey(hostKey)) throw SshException.HostKeyRejected(hostKey)
                val establishedDriver = checkNotNull(targetDriver)
                val establishedBridge = checkNotNull(bridge)
                return SshConnection(
                    driver = establishedDriver,
                    hostKey = hostKey,
                    parent = jump,
                    jumpBridge = establishedBridge,
                )
            } catch (error: Throwable) {
                targetDriver?.disconnect()
                bridge?.close()
                if (bridge == null) jump.driver.disposeChannel(forwardingChannel, sendEof = false)
                jump.disconnect()
                throw error
            }
        }
    }

    private fun requireConnected() {
        if (disconnected.get()) throw SshException.Closed()
    }

    private fun requireAuthenticated() {
        requireConnected()
        if (!authenticated.get()) throw SshException.Protocol("SSH connection is not authenticated")
    }

    suspend fun authenticate(username: String, authentication: SshAuthentication) {
        authenticationLock.withLock {
            requireConnected()
            if (authenticated.get()) throw SshException.Protocol("SSH connection is already authenticated")
            driver.authenticate(username, authentication)
            authenticated.set(true)
        }
    }

    suspend fun openStreamLocal(socketPath: String): SshDataChannel {
        requireAuthenticated()
        return DataChannel(driver, driver.openStreamLocal(socketPath))
    }

    suspend fun openExec(command: String, pty: PtyRequest? = null): SshExecChannel {
        requireAuthenticated()
        return ExecChannel(driver, driver.openExec(command, pty))
    }

    suspend fun sftp(): SshSftpSession {
        requireAuthenticated()
        return SftpSession(driver, driver.openSftp())
    }

    /** Convenience instance form for callers that already hold the jump host. */
    suspend fun connectViaJump(
        targetHost: String,
        targetPort: Int = 22,
        timeoutMs: Int = DEFAULT_CONNECT_TIMEOUT_MS,
        verifyHostKey: suspend (SshHostKey) -> Boolean,
    ): SshConnection = connectViaJump(this, targetHost, targetPort, timeoutMs, verifyHostKey)

    /** Idempotently tears down every resource owned by this connection. */
    suspend fun disconnect() {
        if (!disconnected.compareAndSet(false, true)) return
        var firstFailure: Throwable? = null
        try {
            driver.disconnect()
        } catch (error: Throwable) {
            firstFailure = error
        }
        try {
            jumpBridge?.close()
        } catch (error: Throwable) {
            if (firstFailure == null) firstFailure = error
        }
        try {
            parent?.disconnect()
        } catch (error: Throwable) {
            if (firstFailure == null) firstFailure = error
        }
        firstFailure?.let { throw it }
    }

    private open class DataChannel(
        protected val driver: SshSessionDriver,
        protected val channel: Long,
    ) : SshDataChannel {
        private val closed = AtomicBoolean(false)

        protected fun requireOpen() {
            if (closed.get()) throw SshException.Closed()
        }

        override suspend fun read(maximumBytes: Int): ByteArray? {
            requireOpen()
            return driver.readChannel(channel, maximumBytes)
        }

        override suspend fun write(data: ByteArray) {
            requireOpen()
            driver.writeChannel(channel, data)
        }

        override suspend fun close() {
            if (closed.compareAndSet(false, true)) {
                driver.disposeChannel(channel, sendEof = true)
            }
        }

        protected fun markClosed(): Boolean = closed.compareAndSet(false, true)
    }

    private class ExecChannel(
        driver: SshSessionDriver,
        channel: Long,
    ) : DataChannel(driver, channel), SshExecChannel {
        override suspend fun readStderr(maximumBytes: Int): ByteArray? {
            requireOpen()
            return driver.readChannelStderr(channel, maximumBytes)
        }

        override fun stdout(): Flow<ByteArray> = flow {
            while (true) {
                val chunk = read() ?: break
                emit(chunk)
            }
        }

        override fun stderr(): Flow<ByteArray> = flow {
            while (true) {
                val chunk = readStderr() ?: break
                emit(chunk)
            }
        }

        override suspend fun resize(columns: Int, rows: Int) {
            requireOpen()
            driver.resizePty(channel, columns, rows)
        }

        override suspend fun exitStatus(): Int? {
            requireOpen()
            if (!driver.channelEof(channel)) return null
            if (!markClosed()) return null
            return driver.closeChannelForExitStatus(channel)
        }
    }

    private class SftpSession(
        private val driver: SshSessionDriver,
        private val sftp: Long,
    ) : SshSftpSession {
        private val closed = AtomicBoolean(false)

        private fun requireOpen() {
            if (closed.get()) throw SshException.Closed()
        }

        override suspend fun open(path: String, flags: Int, mode: Int): SshSftpFile {
            requireOpen()
            return SftpFile(driver, driver.openSftpFile(sftp, path, flags, mode))
        }

        override suspend fun rename(source: String, destination: String) {
            requireOpen()
            driver.renameSftp(sftp, source, destination)
        }

        override suspend fun unlink(path: String) {
            requireOpen()
            driver.unlinkSftp(sftp, path)
        }

        override suspend fun mkdir(path: String, mode: Int) {
            requireOpen()
            driver.mkdirSftp(sftp, path, mode)
        }

        override suspend fun close() {
            if (closed.compareAndSet(false, true)) driver.closeSftp(sftp)
        }
    }

    private class SftpFile(
        private val driver: SshSessionDriver,
        private val file: Long,
    ) : SshSftpFile {
        private val closed = AtomicBoolean(false)

        private fun requireOpen() {
            if (closed.get()) throw SshException.Closed()
        }

        override suspend fun read(maximumBytes: Int): ByteArray? {
            requireOpen()
            return driver.readSftpFile(file, maximumBytes)
        }

        override suspend fun write(data: ByteArray) {
            requireOpen()
            driver.writeSftpFile(file, data)
        }

        override suspend fun close() {
            if (closed.compareAndSet(false, true)) driver.closeSftpFile(file)
        }
    }

    /**
     * A Kotlin scheduler around the native socketpair. Native owns its relay
     * descriptor and the child driver owns the returned peer descriptor; this
     * job only performs bounded round-robin transfer calls on the parent
     * session dispatcher.
     */
    private class JumpSocketBridge(
        private val driver: SshSessionDriver,
        private val channel: Long,
    ) {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        private val closed = AtomicBoolean(false)
        private var pump = scope.launch { }

        fun start() {
            pump = scope.launch {
                while (isActive && !closed.get()) {
                    val moved = try {
                        driver.pumpSocketBridge(channel)
                    } catch (_: SshException) {
                        break
                    }
                    if (moved == 0) delay(5) else yield()
                }
            }
        }

        suspend fun close() {
            if (!closed.compareAndSet(false, true)) return
            pump.cancelAndJoin()
            driver.disposeChannel(channel, sendEof = false)
        }
    }
}
