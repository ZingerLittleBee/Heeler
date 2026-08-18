package dev.bybee.heeler.notifications

import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AgentNotificationBannerStoreTest {
    @Test
    fun announcesOnlyHeldBlockedTransitionsAfterTheInitialBaseline() = runTest {
        val store = AgentNotificationBannerStore(
            presentedAgent = { null },
            triggers = { NotificationTriggerPreferences() },
            scope = this,
        )
        val idle = ForegroundAgent(
            hostId = "host",
            paneId = "%1",
            status = "idle",
            agentKind = "claude",
            project = "heeler",
            title = "Fix notifications",
        )
        val blocked = idle.copy(status = "blocked")

        store.agentsDidChange(listOf(idle))
        advanceTimeBy(3_000)
        runCurrent()
        assertNull(store.banner.value)

        store.agentsDidChange(listOf(blocked))
        advanceTimeBy(2_999)
        assertNull(store.banner.value)
        advanceTimeBy(1)
        runCurrent()

        assertEquals("heeler · claude", store.banner.value?.alert?.title)
        assertEquals("Blocked · Fix notifications", store.banner.value?.alert?.body)
    }

    @Test
    fun suppressesAHeldTransitionForTheOpenAgent() = runTest {
        val target = AgentNotificationTarget("host", "%1")
        val store = AgentNotificationBannerStore(
            presentedAgent = { target },
            triggers = { NotificationTriggerPreferences() },
            scope = this,
        )
        val idle = ForegroundAgent("host", "%1", "idle", "claude")

        store.agentsDidChange(listOf(idle))
        store.agentsDidChange(listOf(idle.copy(status = "done")))
        advanceTimeBy(3_000)
        runCurrent()

        assertNull(store.banner.value)
    }
}
