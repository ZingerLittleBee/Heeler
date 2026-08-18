package dev.bybee.heeler.core.transport

/** An unknown host key awaiting the user's trust decision on first connect. */
data class HostKeyCandidate(
    val host: String,
    val port: Int,
    val fingerprint: HostKeyFingerprint,
)

/**
 * TOFU host key policy: trust the fingerprint the user confirmed on first
 * connect, hard-fail when a known Host's key changes. No SSH primitive leaks
 * through this surface — the UI implements the confirmation and injects the
 * store without seeing one.
 */
data class HostKeyPolicy(
    /** Fingerprints of already-trusted Hosts. */
    val knownHosts: KnownHostsStore,
    /**
     * First-connect confirmation, implemented by the UI. Returning false
     * fails the connection with [TransportError.HostKeyRejected] and stores
     * nothing.
     */
    val confirmFirstConnect: suspend (HostKeyCandidate) -> Boolean,
)
