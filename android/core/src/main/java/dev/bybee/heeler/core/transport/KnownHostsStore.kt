package dev.bybee.heeler.core.transport

import android.content.SharedPreferences
import android.util.Base64
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers

/**
 * TOFU persistence: fingerprints are keyed by endpoint and SSH key algorithm,
 * matching OpenSSH's ability to trust more than one host-key algorithm for the
 * same machine. Not a secret: it guards against future impostors; it does not
 * authenticate us.
 */
interface KnownHostsStore {
    suspend fun fingerprints(host: String, port: Int): List<HostKeyFingerprint>
    suspend fun fingerprint(host: String, port: Int, algorithm: String): HostKeyFingerprint?
    suspend fun setFingerprint(fingerprint: HostKeyFingerprint, host: String, port: Int)

    suspend fun fingerprint(host: String, port: Int): HostKeyFingerprint? =
        fingerprints(host, port).firstOrNull()
}

/** Volatile store for tests and previews. */
class InMemoryKnownHostsStore : KnownHostsStore {
    private val mutex = Mutex()
    private val storedFingerprints = mutableMapOf<String, HostKeyFingerprint>()

    override suspend fun fingerprints(host: String, port: Int): List<HostKeyFingerprint> = mutex.withLock {
        val prefix = algorithmKeyPrefix(host, port)
        storedFingerprints.filterKeys { it.startsWith(prefix) }.values.toList()
    }

    override suspend fun fingerprint(
        host: String,
        port: Int,
        algorithm: String,
    ): HostKeyFingerprint? = mutex.withLock {
        storedFingerprints[algorithmKey(host, port, algorithm)]
            ?: storedFingerprints[algorithmKey(host, port, HostKeyFingerprint.UNKNOWN_ALGORITHM)]
    }

    override suspend fun setFingerprint(
        fingerprint: HostKeyFingerprint,
        host: String,
        port: Int,
    ) = mutex.withLock {
        if (fingerprint.algorithm != HostKeyFingerprint.UNKNOWN_ALGORITHM) {
            storedFingerprints.remove(algorithmKey(host, port, HostKeyFingerprint.UNKNOWN_ALGORITHM))
        }
        storedFingerprints[algorithmKey(host, port, fingerprint.algorithm)] = fingerprint
    }

    companion object {
        fun endpointKey(host: String, port: Int): String = "$host:$port"

        fun algorithmKeyPrefix(host: String, port: Int): String {
            val endpoint = endpointKey(host, port)
            return "v2|${endpoint.toByteArray(Charsets.UTF_8).size}|$endpoint|"
        }

        fun algorithmKey(host: String, port: Int, algorithm: String): String =
            algorithmKeyPrefix(host, port) + algorithm
    }
}

/**
 * Persistent Android implementation. The same mutex protects every
 * read-modify-write operation so concurrent first connects cannot lose a
 * trusted algorithm entry.
 */
class SharedPreferencesKnownHostsStore(
    private val preferences: SharedPreferences,
) : KnownHostsStore {
    private val mutex = Mutex()

    override suspend fun fingerprints(host: String, port: Int): List<HostKeyFingerprint> = mutex.withLock {
        val prefix = InMemoryKnownHostsStore.algorithmKeyPrefix(host, port)
        preferences.all.mapNotNull { (key, value) ->
            if (!key.startsWith(prefix)) return@mapNotNull null
            val encoded = value as? String ?: return@mapNotNull null
            val digest = decodeDigest(encoded) ?: return@mapNotNull null
            HostKeyFingerprint.fromDigest(digest, key.removePrefix(prefix))
        } + listOfNotNull(legacyFingerprint(host, port))
    }

    override suspend fun fingerprint(
        host: String,
        port: Int,
        algorithm: String,
    ): HostKeyFingerprint? = mutex.withLock {
        val exact = preferences.getString(
            InMemoryKnownHostsStore.algorithmKey(host, port, algorithm),
            null,
        )?.let(::decodeDigest)?.let { HostKeyFingerprint.fromDigest(it, algorithm) }
        exact ?: legacyFingerprint(host, port)
    }

    override suspend fun setFingerprint(
        fingerprint: HostKeyFingerprint,
        host: String,
        port: Int,
    ) {
        val committed = mutex.withLock {
            withContext(Dispatchers.IO) {
                preferences.edit().apply {
                    if (fingerprint.algorithm != HostKeyFingerprint.UNKNOWN_ALGORITHM) {
                        remove(InMemoryKnownHostsStore.endpointKey(host, port))
                    }
                    putString(
                        InMemoryKnownHostsStore.algorithmKey(host, port, fingerprint.algorithm),
                        Base64.encodeToString(fingerprint.digest, Base64.NO_WRAP),
                    )
                }.commit()
            }
        }
        check(committed) { "Known-host fingerprint persistence failed." }
    }

    private fun legacyFingerprint(host: String, port: Int): HostKeyFingerprint? =
        preferences.getString(InMemoryKnownHostsStore.endpointKey(host, port), null)
            ?.let(::decodeDigest)
            ?.let { HostKeyFingerprint.fromDigest(it) }

    private fun decodeDigest(encoded: String): ByteArray? = try {
        Base64.decode(encoded, Base64.DEFAULT).takeIf { it.isNotEmpty() }
    } catch (_: IllegalArgumentException) {
        null
    }
}
