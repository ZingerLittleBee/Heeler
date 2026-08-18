package dev.bybee.heeler.core.crypto

import java.security.MessageDigest
import java.util.Base64

/**
 * An OpenSSH SHA-256 fingerprint for an SSH public-key blob.
 *
 * The text form is deliberately retained rather than a digest byte array so it can be compared
 * directly to the fingerprint carried by a Pairing Code and shown during host-key confirmation.
 */
@JvmInline
value class HostKeyFingerprint private constructor(val value: String) {
    override fun toString(): String = value

    companion object {
        private const val PREFIX = "SHA256:"
        private val wirePattern = Regex("SHA256:[A-Za-z0-9+/]{43}")

        /** Hashes the raw RFC 4253 host-key blob into OpenSSH's unpadded presentation format. */
        fun fromHostKeyBlob(hostKeyBlob: ByteArray): HostKeyFingerprint {
            val digest = MessageDigest.getInstance("SHA-256").digest(hostKeyBlob)
            val text = PREFIX + Base64.getEncoder().withoutPadding().encodeToString(digest)
            return HostKeyFingerprint(text)
        }

        /** Parses only an exact SHA256 OpenSSH fingerprint backed by a 32-byte digest. */
        fun parse(text: String): HostKeyFingerprint? {
            if (!wirePattern.matches(text)) return null
            val digest = try {
                Base64.getDecoder().decode(text.removePrefix(PREFIX) + "=")
            } catch (_: IllegalArgumentException) {
                return null
            }
            return if (digest.size == 32) HostKeyFingerprint(text) else null
        }
    }
}
