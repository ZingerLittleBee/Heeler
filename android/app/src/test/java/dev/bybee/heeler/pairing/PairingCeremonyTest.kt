package dev.bybee.heeler.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingCeremonyTest {
    @Test
    fun `parses the successful enrollment response exactly`() {
        val response = EnrollmentResponse.parse(
            "HERDR-ENROLL:OK:SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        )

        assertEquals(
            EnrollmentResponse.Enrolled("SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            response,
        )
    }

    @Test
    fun `maps each known enrollment refusal`() {
        assertEquals(
            EnrollmentResponse.Refused(EnrollmentRefusal.Expired),
            EnrollmentResponse.parse("HERDR-ENROLL:ERR:expired"),
        )
        assertEquals(
            EnrollmentResponse.Refused(EnrollmentRefusal.UnknownPairing),
            EnrollmentResponse.parse("HERDR-ENROLL:ERR:unknown_pairing"),
        )
    }

    @Test
    fun `rejects unframed enrollment output`() {
        assertNull(EnrollmentResponse.parse("HERDR-ENROLL:OK:SHA256:too-short"))
        assertNull(EnrollmentResponse.parse("login-shell-noise HERDR-ENROLL:ERR:expired"))
    }
}
