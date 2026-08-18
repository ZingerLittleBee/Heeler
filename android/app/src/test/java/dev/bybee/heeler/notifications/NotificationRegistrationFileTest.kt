package dev.bybee.heeler.notifications

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationRegistrationFileTest {
    @Test
    fun upsertingFcmPreservesForeignDevicesAndUnknownFields() {
        val file = NotificationRegistrationFile.decode(
            """
            {"v":1,"future_top":{"survives":true},"devices":[
              {"token":"apns-token","key":"foreign-key","env":"production","foreign":7},
              {"provider":"fcm","token":"this-device","key":"old","env":"must-go","client_field":"keep","notify":{"blocked":false,"done":false}}
            ]}
            """.trimIndent().encodeToByteArray(),
        )

        val encoded = file.upsertingFcm(
            token = "this-device",
            key = ByteArray(32) { it.toByte() },
            preferences = NotificationTriggerPreferences(blocked = true, done = false),
        ).encoded()
        val result = Json.parseToJsonElement(encoded.decodeToString()).jsonObject
        val devices = result.getValue("devices").jsonArray
        val own = devices[1].jsonObject

        assertEquals(true, result.getValue("future_top").jsonObject.getValue("survives").jsonPrimitive.boolean)
        assertEquals("apns-token", devices[0].jsonObject.getValue("token").jsonPrimitive.content)
        assertEquals(7, devices[0].jsonObject.getValue("foreign").jsonPrimitive.int)
        assertEquals("fcm", own.getValue("provider").jsonPrimitive.content)
        assertEquals("this-device", own.getValue("token").jsonPrimitive.content)
        assertNull(own["env"])
        assertNull(own["client_field"])
        assertTrue(own.getValue("notify").jsonObject.getValue("blocked").jsonPrimitive.boolean)
        assertFalse(own.getValue("notify").jsonObject.getValue("done").jsonPrimitive.boolean)
    }

    @Test(expected = NotificationRegistrationVersionException::class)
    fun refusesParseableNewerRegistrationVersion() {
        NotificationRegistrationFile.decode("""{"v":2,"devices":[]}""".encodeToByteArray())
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsARegistrationKeyThatIsNotThirtyTwoBytes() {
        NotificationRegistrationFile.decode(null).upsertingFcm(
            token = "this-device",
            key = ByteArray(31),
            preferences = NotificationTriggerPreferences(),
        )
    }

    @Test
    fun rendererUsesOneSafePhrasingForBlockedAgent() {
        val alert = AgentNotificationRenderer.alert(
            project = "heeler",
            agentKind = "claude",
            task = "Fix the notification transport",
            status = "blocked",
        )

        assertEquals("heeler · claude", alert.title)
        assertEquals("Blocked · Fix the notification transport", alert.body)
    }
}
