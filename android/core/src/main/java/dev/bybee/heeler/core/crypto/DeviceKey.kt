package dev.bybee.heeler.core.crypto

import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.util.Base64
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters

/**
 * The device's Ed25519 SSH identity. Its private seed is only exposed to the package-local
 * encrypted store and to an in-memory OpenSSH PEM passed directly to libssh2.
 */
class DeviceKey private constructor(private val privateKey: Ed25519PrivateKeyParameters) {
    /** RFC 4253 public-key blob: string "ssh-ed25519" followed by the 32-byte public key. */
    val publicKeyBlob: ByteArray
        get() = SshWireWriter().apply {
            string(KEY_TYPE.toByteArray(Charsets.US_ASCII))
            string(publicKeyBytes)
        }.toByteArray()

    /** Raw Ed25519 public key bytes, useful only for interoperability checks. */
    val publicKeyBytes: ByteArray
        get() = privateKey.generatePublicKey().encoded

    /** A 32-byte private-seed copy for short-lived use inside [DeviceKeyStore]. */
    internal fun seedForStorage(): ByteArray = privateKey.encoded

    /** Emits an authorized_keys-compatible `ssh-ed25519 <base64 blob> <comment>` line. */
    fun openSshPublicKey(comment: String): String {
        validateComment(comment)
        return "$KEY_TYPE ${Base64.getEncoder().encodeToString(publicKeyBlob)} $comment"
    }

    /**
     * Emits an unencrypted `openssh-key-v1` PEM for libssh2's in-memory key authentication API.
     * The returned string is sensitive and must not be logged or persisted by callers.
     */
    fun openSshPrivateKeyPem(comment: String = DEFAULT_COMMENT): String {
        validateComment(comment)
        val seed = seedForStorage()
        try {
            val publicKey = publicKeyBytes
            val publicBlob = publicKeyBlob
            val privateAndPublic = seed + publicKey
            val privateBlock = try {
                SshWireWriter().apply {
                    val check = SecureRandom().nextInt()
                    uint32(check)
                    uint32(check)
                    string(KEY_TYPE.toByteArray(Charsets.US_ASCII))
                    string(publicKey)
                    string(privateAndPublic)
                    string(comment.toByteArray(Charsets.US_ASCII))
                    var padding = 1
                    while (size % OPENSSH_BLOCK_SIZE != 0) {
                        byte(padding++)
                    }
                }.toByteArray()
            } finally {
                privateAndPublic.fill(0)
            }
            val encoded = SshWireWriter().apply {
                raw(OPENSSH_MAGIC)
                string("none".toByteArray(Charsets.US_ASCII))
                string("none".toByteArray(Charsets.US_ASCII))
                string(ByteArray(0))
                uint32(1)
                string(publicBlob)
                string(privateBlock)
            }.toByteArray()
            try {
                val body = Base64.getMimeEncoder(PEM_LINE_WIDTH, byteArrayOf('\n'.code.toByte()))
                    .encodeToString(encoded)
                return "$PEM_BEGIN\n$body\n$PEM_END\n"
            } finally {
                privateBlock.fill(0)
                encoded.fill(0)
            }
        } finally {
            seed.fill(0)
        }
    }

    companion object {
        const val KEY_TYPE = "ssh-ed25519"
        private const val DEFAULT_COMMENT = "heeler@android"
        private const val OPENSSH_BLOCK_SIZE = 8
        private const val PEM_LINE_WIDTH = 70
        private const val PEM_BEGIN = "-----BEGIN OPENSSH PRIVATE KEY-----"
        private const val PEM_END = "-----END OPENSSH PRIVATE KEY-----"
        private val OPENSSH_MAGIC = "openssh-key-v1\u0000".toByteArray(Charsets.US_ASCII)

        fun generate(random: SecureRandom = SecureRandom()): DeviceKey =
            DeviceKey(Ed25519PrivateKeyParameters(random))

        /**
         * Constructs the ephemeral Bootstrap Key from a 32-byte Pairing Code seed.
         *
         * The caller must retain this only in memory and pass its PEM directly to the SSH layer.
         */
        fun fromSeed(seed: ByteArray): DeviceKey? {
            if (seed.size != Ed25519PrivateKeyParameters.KEY_SIZE) return null
            return try {
                DeviceKey(Ed25519PrivateKeyParameters(seed.copyOf(), 0))
            } catch (_: IllegalArgumentException) {
                null
            }
        }

        private fun validateComment(comment: String) {
            require(comment.isNotEmpty() && comment.all { it.code in 0x20..0x7e }) {
                "OpenSSH key comments must be non-empty printable ASCII"
            }
        }
    }
}

/** Minimal writer for OpenSSH/RFC 4253 length-prefixed binary fields. */
private class SshWireWriter {
    private val bytes = ByteArrayOutputStream()

    val size: Int get() = bytes.size()

    fun uint32(value: Int) {
        bytes.write(value ushr 24)
        bytes.write(value ushr 16)
        bytes.write(value ushr 8)
        bytes.write(value)
    }

    fun string(value: ByteArray) {
        uint32(value.size)
        raw(value)
    }

    fun raw(value: ByteArray) {
        bytes.write(value, 0, value.size)
    }

    fun byte(value: Int) {
        bytes.write(value)
    }

    fun toByteArray(): ByteArray = bytes.toByteArray()
}
