package dev.bybee.heeler.core.ssh

/**
 * Thin, nonblocking JNI surface over libssh2. This is a *contract file*: the
 * Zig implementation in `android/native/src/bridge/heeler_ssh.zig` must export
 * exactly these symbols (`Java_dev_bybee_heeler_core_ssh_NativeSsh_<name>`).
 *
 * Threading model (mirrors HeelerSSH's SessionDriver actor): libssh2 sessions
 * are NOT thread-safe. All calls for one session handle MUST come from one
 * thread (the Kotlin `SshSessionDriver` confines them to a single-threaded
 * dispatcher). The session runs in nonblocking mode from creation: any call
 * marked EAGAIN-able returns [AGAIN] when the socket would block; the driver
 * then calls [poll] and retries. Calls for *different* sessions may run on
 * different threads concurrently.
 *
 * Handle discipline: `session` handles come from [sessionNew]; `channel`,
 * `sftp`, and `sftpFile` handles are registry ids scoped to their session.
 * Every handle must be freed exactly once; freeing a session frees its
 * children. Negative return values are libssh2 error codes ([lastError]
 * returns the message); non-negative values are success / byte counts.
 */
object NativeSsh {
    init {
        System.loadLibrary("heeler_jni")
    }

    /** libssh2's LIBSSH2_ERROR_EAGAIN: retry after [poll]. */
    const val AGAIN: Int = -37

    /** Bit flags returned by [blockDirections]. */
    const val DIR_INBOUND: Int = 1
    const val DIR_OUTBOUND: Int = 2

    external fun version(): String

    // --- session lifecycle ---

    /** Creates a session in nonblocking mode. Returns handle, 0 on failure. */
    external fun sessionNew(): Long

    /**
     * Resolves `host`, opens a TCP socket with `connectTimeoutMs`, and stores
     * it on the session. Blocking (bounded by the timeout); call once.
     * Returns 0 or a negative errno-style code.
     */
    external fun connectSocket(session: Long, host: String, port: Int, connectTimeoutMs: Int): Int

    /**
     * Assigns an already-connected, nonblocking descriptor to a session.
     * Ownership transfers to NativeSsh even when handshake later fails. Used
     * exclusively by the jump-host socket bridge.
     */
    external fun connectSocketFd(session: Long, fd: Int): Int

    /** SSH handshake. EAGAIN-able. */
    external fun handshake(session: Long): Int

    /** Raw server host key blob, or null before handshake completes. */
    external fun hostKey(session: Long): ByteArray?

    /** Host key algorithm name (e.g. "ssh-ed25519"), or null. */
    external fun hostKeyType(session: Long): String?

    /** Comma-separated userauth list. EAGAIN yields null with lastErrno == AGAIN. */
    external fun userauthList(session: Long, username: String): String?

    /** EAGAIN-able. Passphrase may be empty for unencrypted keys. */
    external fun userauthPublicKeyFromMemory(
        session: Long,
        username: String,
        publicKeyOpenSsh: ByteArray?,
        privateKeyPem: ByteArray,
        passphrase: String,
    ): Int

    /** EAGAIN-able. */
    external fun userauthPassword(session: Long, username: String, password: String): Int

    external fun isAuthenticated(session: Long): Boolean

    /** Which direction(s) the last EAGAIN was waiting on: DIR_* flags. */
    external fun blockDirections(session: Long): Int

    /**
     * poll(2)s the session socket for the directions from [blockDirections],
     * up to `timeoutMs`. Returns >0 if ready, 0 on timeout, negative on error.
     * The ONLY call that may block; keep timeouts short so the driver loop
     * stays responsive.
     */
    external fun poll(session: Long, timeoutMs: Int): Int

    /** Sends SSH_MSG_DISCONNECT (best-effort, EAGAIN-able). */
    external fun sessionDisconnect(session: Long, description: String): Int

    /** Frees the session, its socket, and all child handles. Never fails. */
    external fun sessionFree(session: Long)

    /** Keepalive configuration + heartbeat (libssh2_keepalive_*). */
    external fun keepaliveConfig(session: Long, intervalSeconds: Int)
    external fun keepaliveSend(session: Long): Int

    /** Message for the most recent error on this session. */
    external fun lastError(session: Long): String
    external fun lastErrno(session: Long): Int

    // --- channels (registry ids; 0 = failure) ---

    /** Opens a session channel (for exec). EAGAIN yields 0 with lastErrno == AGAIN. */
    external fun channelOpenSession(session: Long): Long

    /**
     * Opens an OpenSSH `direct-streamlocal@openssh.com` channel onto a remote
     * Unix socket path. EAGAIN yields 0 with lastErrno == AGAIN.
     */
    external fun channelOpenStreamLocal(session: Long, socketPath: String): Long

    /**
     * Opens an OpenSSH direct-tcpip channel to `host:port`. This underpins
     * jump-host forwarding; a Kotlin-managed socket bridge carries the child
     * SSH session over the returned channel.
     */
    external fun channelOpenDirectTcpIp(session: Long, host: String, port: Int): Long

    /**
     * Creates a nonblocking Unix socket pair for a direct-tcpip channel and
     * returns the child end's raw descriptor. NativeSsh takes ownership of the
     * channel end; pass the returned descriptor exactly once to
     * [connectSocketFd], which takes ownership of it.
     */
    external fun channelCreateSocketBridge(session: Long, channel: Long): Int

    /**
     * Moves bounded data in both directions between one direct-tcpip channel
     * and its socket bridge. It never blocks. A Kotlin coroutine schedules it
     * alongside all other session work.
     */
    external fun channelPumpSocketBridge(session: Long, channel: Long): Int

    /** EAGAIN-able. `term` e.g. "xterm-256color". */
    external fun channelRequestPty(session: Long, channel: Long, term: String, cols: Int, rows: Int): Int

    external fun channelResizePty(session: Long, channel: Long, cols: Int, rows: Int): Int

    /** EAGAIN-able. Starts `command` on a session channel. */
    external fun channelExec(session: Long, channel: Long, command: String): Int

    /**
     * Reads stream 0 into `buffer`. Returns bytes read, 0 on channel EOF,
     * or AGAIN. Never blocks.
     */
    external fun channelRead(session: Long, channel: Long, buffer: ByteArray): Int

    /** Reads stderr (stream 1). Same semantics as [channelRead]. */
    external fun channelReadStderr(session: Long, channel: Long, buffer: ByteArray): Int

    /** Writes `length` bytes from `offset`. Returns bytes written or AGAIN. */
    external fun channelWrite(session: Long, channel: Long, data: ByteArray, offset: Int, length: Int): Int

    external fun channelSendEof(session: Long, channel: Long): Int
    external fun channelEof(session: Long, channel: Long): Boolean
    external fun channelClose(session: Long, channel: Long): Int

    /** Valid after close+EOF; -1 when unavailable. */
    external fun channelExitStatus(session: Long, channel: Long): Int

    external fun channelFree(session: Long, channel: Long)

    // --- SFTP ---

    /** EAGAIN yields 0 with lastErrno == AGAIN. */
    external fun sftpInit(session: Long): Long

    /**
     * Opens a remote file. `flags`: bitwise OR of the SFTP_OPEN_* constants
     * below; `mode` is the octal permission set for creation.
     * EAGAIN yields 0 with lastErrno == AGAIN.
     */
    external fun sftpOpen(session: Long, sftp: Long, path: String, flags: Int, mode: Int): Long

    external fun sftpWrite(session: Long, file: Long, data: ByteArray, offset: Int, length: Int): Int
    external fun sftpRead(session: Long, file: Long, buffer: ByteArray): Int
    external fun sftpCloseHandle(session: Long, file: Long): Int

    /** EAGAIN-able. POSIX rename semantics with overwrite. */
    external fun sftpRename(session: Long, sftp: Long, source: String, destination: String): Int

    external fun sftpUnlink(session: Long, sftp: Long, path: String): Int
    external fun sftpMkdir(session: Long, sftp: Long, path: String, mode: Int): Int

    /** Last SFTP protocol error code (LIBSSH2_FX_*). */
    external fun sftpLastError(session: Long, sftp: Long): Int
    external fun sftpShutdown(session: Long, sftp: Long): Int

    const val SFTP_OPEN_READ: Int = 0x1
    const val SFTP_OPEN_WRITE: Int = 0x2
    const val SFTP_OPEN_APPEND: Int = 0x4
    const val SFTP_OPEN_CREATE: Int = 0x8
    const val SFTP_OPEN_TRUNCATE: Int = 0x10
    const val SFTP_OPEN_EXCLUSIVE: Int = 0x20
}
