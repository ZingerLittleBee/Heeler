package dev.bybee.heeler.core.transport

/**
 * Transport-level failures: a closed taxonomy so every screen maps errors to
 * user guidance consistently instead of string-matching.
 */
sealed class TransportError(message: String) : Exception(message) {
    /** The SSH server could not be reached before authentication. */
    data class SshUnreachable(val detail: String) : TransportError(detail)

    /**
     * The first hop failed: the Host may be healthy, but the Jump Host is
     * unreachable, rejected our key, or presented an unexpected host key.
     */
    data class JumpHostFailed(val underlying: TransportError) : TransportError(underlying.message.orEmpty())

    /** The Jump Host prohibits the direct-tcpip channel required to reach the Host. */
    data object TcpForwardingUnavailable : TransportError("SSH TCP forwarding is unavailable.")

    /** The Host rejected our credentials. */
    data object AuthenticationFailed : TransportError("SSH authentication failed.")

    /** The in-memory device key could not be decoded. */
    data object DeviceKeyCorrupt : TransportError("The device key is corrupt.")

    /** The user declined an unknown Host's key; nothing was stored. */
    data class HostKeyRejected(val presented: HostKeyFingerprint) : TransportError("The host key was rejected.")

    /** A known Host presented a different key; the trusted fingerprint is untouched. */
    data class HostKeyMismatch(
        val known: HostKeyFingerprint,
        val presented: HostKeyFingerprint,
    ) : TransportError("The host key changed.")

    /** The herdr API socket path does not exist on the Host. */
    data class SocketNotFound(val path: String) : TransportError("Socket not found: $path")

    /**
     * libssh2 cannot distinguish an SSH policy rejection from a stale socket
     * file, so presenting a narrower cause would be fabricated precision.
     */
    data class StreamLocalOpenFailed(val path: String) : TransportError("Cannot open stream-local channel: $path")

    /** The server speaks a herdr protocol version this build cannot drive. */
    data class ProtocolVersionMismatch(val server: Int, val supported: Int) :
        TransportError("Unsupported herdr protocol $server; minimum is $supported.")

    /** A home-relative socket could not be resolved. */
    data class HomeDirectoryUnresolvable(val detail: String) : TransportError(detail)

    /** A second long-lived events channel was requested. */
    data object EventsChannelAlreadyOpen : TransportError("The events channel is already open.")

    /** A second terminal channel or output reader was requested. */
    data object TerminalChannelAlreadyOpen : TransportError("The terminal channel is already open.")

    /** The request exceeded its deadline and its channel was closed. */
    data object TimedOut : TransportError("The transport request timed out.")

    /** The request was cancelled before completing. */
    data object Cancelled : TransportError("The transport request was cancelled.")

    /** The channel produced bytes that do not decode as a herdr response. */
    data class MalformedResponse(val detail: String) : TransportError(detail)

    /** herdr received the request and rejected it on its own terms. */
    data class ApiRejected(val code: String, val serverMessage: String) : TransportError(serverMessage)

    /** The channel failed outside the known error shapes. */
    data class ChannelFailed(val detail: String) : TransportError(detail)

    /**
     * Whether reconnecting without user intervention can plausibly recover.
     * Configuration, trust, authentication, and protocol failures instead
     * stop so the UI can explain the required action.
     *
     * [StreamLocalOpenFailed] is configuration-class: neither of the two
     * causes it cannot tell apart — a stopped herdr or disabled stream-local
     * forwarding — resolves without the user acting on the Host (ADR 0011).
     */
    val isRetryable: Boolean
        get() = when (this) {
            // A rejection is retryable because herdr's error codes are open-ended
            // and most describe a target that moved, not a broken setup.
            is SshUnreachable, TimedOut, Cancelled, is ChannelFailed, is ApiRejected -> true
            AuthenticationFailed,
            TcpForwardingUnavailable,
            DeviceKeyCorrupt,
            is HostKeyRejected,
            is HostKeyMismatch,
            is SocketNotFound,
            is ProtocolVersionMismatch,
            is StreamLocalOpenFailed,
            is HomeDirectoryUnresolvable,
            EventsChannelAlreadyOpen,
            TerminalChannelAlreadyOpen,
            is MalformedResponse -> false
            is JumpHostFailed -> underlying.isRetryable
        }
}

/** An error returned by herdr inside a response envelope. */
class HerdrApiError(
    val code: String,
    val serverMessage: String,
) : Exception(serverMessage)
