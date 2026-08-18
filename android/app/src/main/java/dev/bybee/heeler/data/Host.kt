package dev.bybee.heeler.data

import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * A configured remote Host. Secrets are deliberately excluded: password bytes live in
 * [HostPasswordStore] and the Device Key is owned by core.crypto.
 */
@Serializable
data class Host(
    val id: String = UUID.randomUUID().toString(),
    val displayName: String? = null,
    val address: String,
    val port: Int = DEFAULT_PORT,
    val username: String,
    val auth: HostAuth = HostAuth.DeviceKey,
    /** Null means the default herdr session. */
    val sessionName: String? = null,
    /** Null means connect directly. */
    val jumpHost: JumpHostSpec? = null,
    /**
     * The last trusted target fingerprint in OpenSSH SHA-256 form. An empty value means the
     * first connection still requires explicit TOFU confirmation.
     */
    val hostKeyFingerprint: String = "",
) {
    init {
        require(id.isNotBlank()) { "Host id cannot be blank." }
        require(runCatching { UUID.fromString(id) }.isSuccess) { "Host id must be a UUID." }
        require(address.isNotBlank()) { "Host address cannot be blank." }
        require(port in 1..65535) { "Host port must be in 1..65535." }
        require(username.isNotBlank()) { "Host username cannot be blank." }
        sessionName?.let {
            require(it.isNotBlank()) { "A stored session name cannot be blank." }
        }
    }

    val name: String
        get() = displayName?.trim().takeUnless { it.isNullOrEmpty() } ?: "$username@$address"

    val isDefaultSession: Boolean get() = sessionName == null

    companion object {
        const val DEFAULT_PORT = 22
    }
}

/** Authentication material selected for a Host; no secret bytes are persisted in this type. */
@Serializable
sealed interface HostAuth {
    @Serializable
    @SerialName("device_key")
    data object DeviceKey : HostAuth

    /** [recordRef] points to an encrypted app-private record, never a password literal. */
    @Serializable
    @SerialName("password")
    data class Password(val recordRef: String) : HostAuth {
        init {
            require(recordRef.isNotBlank()) { "Password record reference cannot be blank." }
        }
    }
}

/**
 * The optional SSH hop used to reach a Host. It intentionally has no independent credentials:
 * both hops use the Host's selected [HostAuth], matching the native app's connection model.
 */
@Serializable
data class JumpHostSpec(
    val address: String,
    val port: Int = Host.DEFAULT_PORT,
    /** Blank is not persisted; forms resolve it to the target Host username. */
    val username: String,
) {
    init {
        require(address.isNotBlank()) { "Jump Host address cannot be blank." }
        require(port in 1..65535) { "Jump Host port must be in 1..65535." }
        require(username.isNotBlank()) { "Jump Host username cannot be blank." }
    }
}
