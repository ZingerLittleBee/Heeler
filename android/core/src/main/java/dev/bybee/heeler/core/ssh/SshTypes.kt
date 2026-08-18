package dev.bybee.heeler.core.ssh

import kotlinx.coroutines.flow.Flow

/** Raw server host-key material supplied to the caller's TOFU policy. */
data class SshHostKey(
    val algorithm: String,
    val rawKey: ByteArray,
)

/** Authentication material is used only for the immediate native auth call. */
sealed interface SshAuthentication {
    /** Password remains caller-owned and is never retained by the connection. */
    class Password(val value: CharArray) : SshAuthentication

    /** In-memory OpenSSH or PEM private key material; it is never persisted. */
    class PublicKey(
        val privateKeyPem: ByteArray,
        val publicKeyOpenSsh: ByteArray? = null,
        val passphrase: CharArray = CharArray(0),
    ) : SshAuthentication
}

/** PTY parameters used for interactive exec channels such as `herdr agent attach`. */
data class PtyRequest(
    val term: String = "xterm-256color",
    val columns: Int,
    val rows: Int,
) {
    init {
        require(term.isNotBlank()) { "PTY terminal type must not be blank" }
        require(columns > 0) { "PTY columns must be positive" }
        require(rows > 0) { "PTY rows must be positive" }
    }
}

/** A bidirectional byte stream on one SSH channel. */
interface SshDataChannel {
    /** Reads up to [maximumBytes], returning null only after remote EOF. */
    suspend fun read(maximumBytes: Int = DEFAULT_BUFFER_SIZE): ByteArray?

    /** Writes the complete byte sequence or throws without reporting partial success. */
    suspend fun write(data: ByteArray)

    /** Sends EOF, closes, and frees the native channel exactly once. */
    suspend fun close()

    companion object {
        const val DEFAULT_BUFFER_SIZE: Int = 32 * 1024
    }
}

/** An exec channel, optionally with a PTY, with independently readable stderr. */
interface SshExecChannel : SshDataChannel {
    suspend fun readStderr(maximumBytes: Int = SshDataChannel.DEFAULT_BUFFER_SIZE): ByteArray?

    fun stdout(): Flow<ByteArray>

    fun stderr(): Flow<ByteArray>

    suspend fun resize(columns: Int, rows: Int)

    /**
     * Returns the remote process status after EOF and closes the channel.
     * Returns null until remote EOF has been observed.
     */
    suspend fun exitStatus(): Int?
}

/** One SFTP subsystem attached to an authenticated SSH connection. */
interface SshSftpSession {
    suspend fun open(
        path: String,
        flags: Int,
        mode: Int = DEFAULT_FILE_MODE,
    ): SshSftpFile

    suspend fun rename(source: String, destination: String)

    suspend fun unlink(path: String)

    suspend fun mkdir(path: String, mode: Int = DEFAULT_DIRECTORY_MODE)

    suspend fun close()

    companion object {
        const val DEFAULT_FILE_MODE: Int = 0x180 // 0600
        const val DEFAULT_DIRECTORY_MODE: Int = 0x1ED // 0755
    }
}

/** A single open SFTP file. */
interface SshSftpFile {
    /** Reads up to [maximumBytes], returning null only at the SFTP EOF. */
    suspend fun read(maximumBytes: Int = SshDataChannel.DEFAULT_BUFFER_SIZE): ByteArray?

    /** Writes the complete byte sequence or throws without reporting partial success. */
    suspend fun write(data: ByteArray)

    suspend fun close()
}

sealed class SshException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class NativeFailure(
        val operation: String,
        val code: Int,
        detail: String,
    ) : SshException("$operation failed (code=$code): $detail")

    class HostKeyRejected(hostKey: SshHostKey) :
        SshException("host key rejected for ${hostKey.algorithm}")

    class Closed : SshException("SSH connection is closed")

    class TimedOut(operation: String, timeoutMs: Long) :
        SshException("$operation timed out after ${timeoutMs}ms")

    class Protocol(detail: String) : SshException(detail)
}
