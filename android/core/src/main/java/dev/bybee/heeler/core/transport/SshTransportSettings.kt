package dev.bybee.heeler.core.transport

import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** In-memory authentication material. It is never persisted by this layer. */
sealed interface SshCredentials {
    data class Password(val password: CharArray) : SshCredentials

    /**
     * OpenSSH/PEM private-key material passed to libssh2 from memory only.
     * [publicKeyOpenSsh] is optional because libssh2 can derive it from a
     * private key when needed.
     */
    data class PublicKey(
        val privateKeyPem: ByteArray,
        val publicKeyOpenSsh: ByteArray? = null,
        val passphrase: CharArray = CharArray(0),
    ) : SshCredentials
}

/** How to reach one Host, authenticate, and find its herdr socket. */
data class SshTransportSettings(
    val host: String,
    val port: Int,
    val username: String,
    val credentials: SshCredentials,
    /** TOFU policy: trusted store plus UI first-connect confirmation. */
    val hostKeyPolicy: HostKeyPolicy,
    /** Which herdr socket to reach. */
    val socket: HerdrSocketLocation,
    /** Optional Jump Host, authenticated before the target Host. */
    val jump: SshJumpSettings? = null,
    /** Wakes a stopped herdr server when stream-local opening fails. */
    val wakeCommand: String = DEFAULT_WAKE_COMMAND,
    /** Official Host-local session discovery command. */
    val sessionListCommand: String = DEFAULT_SESSION_LIST_COMMAND,
    /** Marker-delimited executable discovery command. */
    val agentDiscoveryCommand: String = defaultAgentDiscoveryCommand(),
    /** PTY exec command for `herdr agent attach`. */
    val attachCommand: String = DEFAULT_ATTACH_COMMAND,
    /** Prints marker-delimited remote `$HOME`. */
    val homeCommand: String = DEFAULT_HOME_COMMAND,
    /** Creates a private Host staging root. */
    val stageDirectoryCommand: String = DEFAULT_STAGE_DIRECTORY_COMMAND,
    /** Official Host-local plugin listing command. */
    val pluginListCommand: String = DEFAULT_PLUGIN_LIST_COMMAND,
    /** Marker-delimited plugin config-dir command. */
    val notificationConfigDirCommand: String = DEFAULT_NOTIFICATION_CONFIG_DIR_COMMAND,
    /** Bounds queue wait and channel exchange; slow hosts still get 15 seconds. */
    val requestTimeout: Duration = DEFAULT_REQUEST_TIMEOUT,
) {
    init {
        require(host.isNotBlank()) { "SSH host cannot be blank." }
        require(port in 1..65535) { "SSH port is outside 1...65535." }
        require(username.isNotBlank()) { "SSH username cannot be blank." }
        require(!requestTimeout.isNegative() && requestTimeout != Duration.ZERO) {
            "SSH request timeout must be positive."
        }
    }

    companion object {
        const val DEFAULT_SESSION_LIST_COMMAND = "herdr session list --json"
        const val DEFAULT_WAKE_COMMAND = "herdr remote-client-bridge"
        const val DEFAULT_ATTACH_COMMAND = "herdr agent attach"
        const val DEFAULT_HOME_COMMAND = "printf '__HEELER_HOME__=%s\\n' \"\$HOME\""
        const val DEFAULT_PLUGIN_LIST_COMMAND = "herdr plugin list --json"
        const val AGENT_AVAILABILITY_MARKER = "__HEELER_AGENT_KIND__="
        const val NOTIFICATION_PLUGIN_ID = "heeler"
        val LEGACY_NOTIFICATION_PLUGIN_IDS = listOf("herdr-mobile.pairing")
        const val NOTIFICATION_PLUGIN_ID_TOKEN = "__HEELER_PLUGIN_ID__"
        const val DEFAULT_STAGE_DIRECTORY_COMMAND = "/bin/sh -c 'umask 077; " +
            "directory=\$(mktemp -d \"\${TMPDIR:-/tmp}/heeler.XXXXXXXX\") || exit 1; " +
            "printf \"__HEELER_STAGE_DIR__=%s\\n\" \"\$directory\"'"
        const val DEFAULT_NOTIFICATION_CONFIG_DIR_COMMAND =
            "/bin/sh -c 'printf \"__HEELER_PLUGIN_CONFIG_DIR__=%s\\n\" " +
                "\"\$(herdr plugin config-dir $NOTIFICATION_PLUGIN_ID_TOKEN)\"'"
        val DEFAULT_REQUEST_TIMEOUT: Duration = 15.seconds

        /**
         * Commands emit canonical kinds behind a marker so login-shell noise
         * cannot become a false positive. Only fixed, compiled-in executables
         * are interpolated into this script.
         */
        fun defaultAgentDiscoveryCommand(): String {
            val checks = SupportedAgentKind.entries.joinToString("; ") { kind ->
                "command -v ${kind.executable} >/dev/null 2>&1 && " +
                    "printf \"$AGENT_AVAILABILITY_MARKER%s\\n\" \"${kind.rawValue}\""
            }
            return "/bin/sh -c '$checks; exit 0'"
        }
    }
}

/**
 * The Jump Host in front of a Host. Its own host key uses the same TOFU policy,
 * keyed by its own endpoint, so both hops must be confirmed before trust.
 */
data class SshJumpSettings(
    val host: String,
    val port: Int = 22,
    val username: String,
    val credentials: SshCredentials,
) {
    init {
        require(host.isNotBlank()) { "Jump Host cannot be blank." }
        require(port in 1..65535) { "Jump Host port is outside 1...65535." }
        require(username.isNotBlank()) { "Jump Host username cannot be blank." }
    }
}
