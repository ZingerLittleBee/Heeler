package dev.bybee.heeler.pairing

import dev.bybee.heeler.core.crypto.DeviceKey
import dev.bybee.heeler.core.crypto.HostKeyFingerprint
import dev.bybee.heeler.core.crypto.PairingCode
import dev.bybee.heeler.core.ssh.SshAuthentication
import dev.bybee.heeler.core.ssh.SshConnection
import dev.bybee.heeler.core.ssh.SshException
import dev.bybee.heeler.core.ssh.SshExecChannel
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeout

/**
 * One-shot SSH implementation of Pairing. It intentionally never uses TOFU: each connection is
 * checked against the Pairing Code pin before Bootstrap or Device Key authentication begins.
 */
class SshPairingConnector(
    private val perAddressTimeoutMs: Int = 4_000,
    private val enrollmentTimeoutMs: Long = 20_000,
    private val deviceKeyComment: String = "heeler",
) : PairingConnector {
    init {
        require(perAddressTimeoutMs > 0) { "Per-address timeout must be positive." }
        require(enrollmentTimeoutMs > 0) { "Enrollment timeout must be positive." }
    }

    override suspend fun pair(
        code: PairingCode,
        deviceKey: DeviceKey,
        onStep: (PairingStep) -> Unit,
    ): PairingResult {
        val bootstrap = code.bootstrap
        if (bootstrap == null) {
            onStep(PairingStep.Reach)
            val reached = reach(
                code,
                deviceKey,
                PairingCeremonyError.VerificationFailed(
                    "The Host did not accept this Device Key; it is not enrolled there yet.",
                ),
            )
            closeSilently(reached.connection)
            return PairingResult(
                address = reached.address,
                port = code.port,
                username = code.username,
                hostKeyFingerprint = reached.fingerprint.value,
            )
        }

        val bootstrapSeed = bootstrap.seed
        val bootstrapKey = try {
            DeviceKey.fromSeed(bootstrapSeed) ?: throw PairingCeremonyError.BootstrapRejected
        } finally {
            bootstrapSeed.fill(0)
        }

        onStep(PairingStep.Reach)
        val reached = reach(code, bootstrapKey, PairingCeremonyError.BootstrapRejected)
        try {
            onStep(PairingStep.Enroll)
            enroll(deviceKey, reached.connection)
        } finally {
            closeSilently(reached.connection)
        }

        onStep(PairingStep.Verify)
        return verify(code, reached.address, deviceKey)
    }

    /** A key-match selects an address. Authentication rejection is authoritative, not a failover. */
    private suspend fun reach(
        code: PairingCode,
        identity: DeviceKey,
        authenticationFailure: PairingCeremonyError,
    ): ReachedHost {
        val attempts = ArrayList<String>(code.addresses.size)
        for (address in code.addresses) {
            var presented: HostKeyFingerprint? = null
            val connection = try {
                SshConnection.connect(
                    host = address,
                    port = code.port,
                    timeoutMs = perAddressTimeoutMs,
                ) { hostKey ->
                    HostKeyFingerprint.fromHostKeyBlob(hostKey.rawKey).also { fingerprint ->
                        presented = fingerprint
                    } == code.hostKeyFingerprint
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: SshException.HostKeyRejected) {
                attempts += "$address: host key did not match the Pairing Code pin"
                continue
            } catch (error: Throwable) {
                attempts += "$address: ${error.detailForUser()}"
                continue
            }

            try {
                authenticate(connection, code.username, identity)
                return ReachedHost(connection, address, checkNotNull(presented))
            } catch (error: CancellationException) {
                closeSilently(connection)
                throw error
            } catch (error: SshException.NativeFailure) {
                closeSilently(connection)
                if (error.operation == "public-key authentication") throw authenticationFailure
                attempts += "$address: ${error.detailForUser()}"
            } catch (error: SshException.Protocol) {
                closeSilently(connection)
                throw authenticationFailure
            } catch (error: SshException) {
                closeSilently(connection)
                attempts += "$address: ${error.detailForUser()}"
            }
        }
        throw PairingCeremonyError.HostUnreachable(attempts.joinToString("; "))
    }

    /** The bootstrap entrypoint accepts precisely one Device Key public-key line. */
    private suspend fun enroll(deviceKey: DeviceKey, connection: SshConnection) {
        val line = deviceKey.openSshPublicKey(deviceKeyComment)
        if (line.contains('\u0000') || line.contains('\n') || line.contains('\r') ||
            line.encodeToByteArray().size >= MAXIMUM_ENROLLMENT_LINE_BYTES
        ) {
            throw PairingCeremonyError.EnrollmentFailed(
                "The Device Key submission was not one bounded line.",
            )
        }
        val response = try {
            readEnrollmentLine(connection, line)
        } catch (error: CancellationException) {
            throw error
        } catch (error: PairingCeremonyError) {
            throw error
        } catch (error: Throwable) {
            throw PairingCeremonyError.EnrollmentFailed(error.detailForUser())
        }

        when (val parsed = EnrollmentResponse.parse(response)) {
            is EnrollmentResponse.Enrolled -> {
                val expected = HostKeyFingerprint.fromHostKeyBlob(deviceKey.publicKeyBlob).value
                if (parsed.deviceKeyFingerprint != expected) {
                    throw PairingCeremonyError.EnrollmentFailed(
                        "The Host enrolled a different Device Key.",
                    )
                }
            }
            is EnrollmentResponse.Refused -> throw PairingCeremonyError.EnrollmentRefused(parsed.refusal)
            null -> throw PairingCeremonyError.EnrollmentFailed("The Enrollment response was not recognized.")
        }
    }

    private suspend fun readEnrollmentLine(connection: SshConnection, publicKeyLine: String): String =
        withTimeout(enrollmentTimeoutMs) {
            val channel = connection.openExec("heeler-enroll")
            try {
                val request = (publicKeyLine + "\n").encodeToByteArray()
                try {
                    channel.write(request)
                } finally {
                    request.fill(0)
                }
                channel.readSingleLine(MAXIMUM_ENROLLMENT_LINE_BYTES)
                    ?: throw PairingCeremonyError.EnrollmentFailed(
                        "The Enrollment entrypoint closed without answering.",
                    )
            } finally {
                closeChannelSilently(channel)
            }
        }

    /** A successful enrollment is only useful after a fresh pinned Device Key authentication. */
    private suspend fun verify(code: PairingCode, address: String, deviceKey: DeviceKey): PairingResult {
        var presented: HostKeyFingerprint? = null
        val connection = try {
            SshConnection.connect(
                host = address,
                port = code.port,
                timeoutMs = perAddressTimeoutMs,
            ) { hostKey ->
                HostKeyFingerprint.fromHostKeyBlob(hostKey.rawKey).also { fingerprint ->
                    presented = fingerprint
                } == code.hostKeyFingerprint
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw PairingCeremonyError.VerificationFailed(error.detailForUser())
        }
        try {
            authenticate(connection, code.username, deviceKey)
            return PairingResult(
                address = address,
                port = code.port,
                username = code.username,
                hostKeyFingerprint = checkNotNull(presented).value,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            throw PairingCeremonyError.VerificationFailed(
                "The Host did not accept the enrolled Device Key.",
            )
        } finally {
            closeSilently(connection)
        }
    }

    private suspend fun authenticate(connection: SshConnection, username: String, key: DeviceKey) {
        val privateKey = key.openSshPrivateKeyPem(deviceKeyComment).encodeToByteArray()
        val publicKey = key.openSshPublicKey(deviceKeyComment).encodeToByteArray()
        try {
            connection.authenticate(
                username,
                SshAuthentication.PublicKey(privateKeyPem = privateKey, publicKeyOpenSsh = publicKey),
            )
        } finally {
            privateKey.fill(0)
            publicKey.fill(0)
        }
    }

    private data class ReachedHost(
        val connection: SshConnection,
        val address: String,
        val fingerprint: HostKeyFingerprint,
    )

    private companion object {
        const val MAXIMUM_ENROLLMENT_LINE_BYTES = 4_096
    }
}

private suspend fun SshExecChannel.readSingleLine(maximumBytes: Int): String? {
    val bytes = ByteArrayOutputStream()
    while (true) {
        val chunk = read(maximumBytes = minOf(1024, maximumBytes)) ?: return null
        for (byte in chunk) {
            if (byte == '\n'.code.toByte()) return bytes.toByteArray().decodeToString()
            if (bytes.size() >= maximumBytes) {
                throw PairingCeremonyError.EnrollmentFailed("The Enrollment response was too large.")
            }
            bytes.write(byte.toInt())
        }
    }
}

private suspend fun closeSilently(connection: SshConnection) {
    try {
        connection.disconnect()
    } catch (_: Throwable) {
        // A completed or failed ceremony retains its original outcome.
    }
}

private suspend fun closeChannelSilently(channel: SshExecChannel) {
    try {
        channel.close()
    } catch (_: Throwable) {
        // The already-read protocol result remains authoritative.
    }
}

private fun Throwable.detailForUser(): String = message?.take(200)?.takeIf(String::isNotBlank)
    ?: javaClass.simpleName
