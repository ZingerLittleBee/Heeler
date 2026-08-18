package dev.bybee.heeler.core.transport

import android.util.Base64
import java.security.MessageDigest

/**
 * An OpenSSH-style host key fingerprint: SHA-256 over the SSH wire-format
 * public key blob. This is what the user confirms on first connect and what
 * the known-hosts store persists for TOFU.
 */
class HostKeyFingerprint private constructor(
    private val bytes: ByteArray,
    val algorithm: String,
) {
    /** Marker for legacy entries that predate algorithm-aware persistence. */
    companion object {
        const val UNKNOWN_ALGORITHM = "*"

        /** Constructs a fingerprint from one SSH public-key wire blob. */
        fun fromPublicKeyBlob(publicKeyBlob: ByteArray): HostKeyFingerprint =
            HostKeyFingerprint(
                MessageDigest.getInstance("SHA-256").digest(publicKeyBlob),
                readAlgorithm(publicKeyBlob) ?: UNKNOWN_ALGORITHM,
            )

        /** Reconstructs a fingerprint from a previously stored SHA-256 digest. */
        fun fromDigest(
            digest: ByteArray,
            algorithm: String = UNKNOWN_ALGORITHM,
        ): HostKeyFingerprint = HostKeyFingerprint(digest.copyOf(), algorithm)

        private fun readAlgorithm(blob: ByteArray): String? {
            if (blob.size < Int.SIZE_BYTES) return null
            val length = ((blob[0].toInt() and 0xff) shl 24) or
                ((blob[1].toInt() and 0xff) shl 16) or
                ((blob[2].toInt() and 0xff) shl 8) or
                (blob[3].toInt() and 0xff)
            if (length !in 1..256 || blob.size < Int.SIZE_BYTES + length) return null
            val algorithm = blob.copyOfRange(Int.SIZE_BYTES, Int.SIZE_BYTES + length)
                .toString(Charsets.UTF_8)
            return algorithm.takeIf { value ->
                value.all { it.code in 0x21..0x7e }
            }
        }
    }

    /** The 32-byte SHA-256 digest. Returned defensively because arrays mutate. */
    val digest: ByteArray get() = bytes.copyOf()

    /** The presentation OpenSSH prints: `SHA256:<base64 without padding>`. */
    val displayString: String
        get() = "SHA256:" + Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.NO_PADDING)

    override fun equals(other: Any?): Boolean =
        other is HostKeyFingerprint && bytes.contentEquals(other.bytes)

    override fun hashCode(): Int = bytes.contentHashCode()

    override fun toString(): String = displayString
}
