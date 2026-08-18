package dev.bybee.heeler.pairing

import dev.bybee.heeler.core.crypto.DeviceKey
import dev.bybee.heeler.core.crypto.PairingCode

/** The ordered stages of a Pairing ceremony; failures always retain their originating stage. */
enum class PairingStep(val label: String) {
    Parse("Reading Pairing Code"),
    Reach("Reaching Host"),
    Authenticate("Authenticating Bootstrap Key"),
    Enroll("Enrolling Device Key"),
    Verify("Verifying Device Key"),
}

/** The complete ceremony boundary, separate from Transport's herdr API connection semantics. */
interface PairingConnector {
    suspend fun pair(
        code: PairingCode,
        deviceKey: DeviceKey,
        onStep: (PairingStep) -> Unit,
    ): PairingResult
}

/** A completed ceremony's facts. Only this result may become a persisted Host. */
data class PairingResult(
    val address: String,
    val port: Int,
    val username: String,
    val hostKeyFingerprint: String,
)

/** Enrollment failures returned by the forced bootstrap command. */
sealed interface EnrollmentRefusal {
    data object UnknownPairing : EnrollmentRefusal
    data object Expired : EnrollmentRefusal
    data object InvalidKey : EnrollmentRefusal
    data object NoInput : EnrollmentRefusal
    data class Unrecognized(val code: String) : EnrollmentRefusal

    companion object {
        fun fromWire(code: String): EnrollmentRefusal = when (code) {
            "unknown_pairing" -> UnknownPairing
            "expired" -> Expired
            "invalid_key" -> InvalidKey
            "no_input" -> NoInput
            else -> Unrecognized(code)
        }
    }
}

/** Closed failure taxonomy for Pairing copy and retry decisions. */
sealed class PairingCeremonyError(message: String) : Exception(message) {
    data class HostUnreachable(val detail: String) : PairingCeremonyError(detail)
    data object BootstrapRejected : PairingCeremonyError("The Bootstrap Key was rejected.")
    data class EnrollmentRefused(val refusal: EnrollmentRefusal) :
        PairingCeremonyError("Enrollment was refused.")
    data class EnrollmentFailed(val detail: String) : PairingCeremonyError(detail)
    data class VerificationFailed(val detail: String) : PairingCeremonyError(detail)

    val step: PairingStep
        get() = when (this) {
            is HostUnreachable -> PairingStep.Reach
            BootstrapRejected -> PairingStep.Authenticate
            is EnrollmentRefused, is EnrollmentFailed -> PairingStep.Enroll
            is VerificationFailed -> PairingStep.Verify
        }
}

/** Exact, line-based response emitted by the Enrollment forced command. */
sealed interface EnrollmentResponse {
    data class Enrolled(val deviceKeyFingerprint: String) : EnrollmentResponse
    data class Refused(val refusal: EnrollmentRefusal) : EnrollmentResponse

    companion object {
        private val successful = Regex("HERDR-ENROLL:OK:(SHA256:[A-Za-z0-9+/]{43})")
        private val rejected = Regex("HERDR-ENROLL:ERR:([a-z_]+)")

        fun parse(line: String): EnrollmentResponse? =
            successful.matchEntire(line)?.groupValues?.get(1)?.let(::Enrolled)
                ?: rejected.matchEntire(line)?.groupValues?.get(1)
                    ?.let { Refused(EnrollmentRefusal.fromWire(it)) }
    }
}
