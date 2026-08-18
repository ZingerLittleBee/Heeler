package dev.bybee.heeler.console

import dev.bybee.heeler.core.wire.AgentStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConsoleAgentTest {
    @Test
    fun `sorts actionable statuses before working idle and unknown`() {
        val sorted = listOf(
            agent("unknown", "5"),
            agent("idle", "4"),
            agent("working", "3"),
            agent("done", "2"),
            agent("blocked", "1"),
        ).consoleSorted()

        assertEquals(listOf("1", "2", "3", "4", "5"), sorted.map(ConsoleAgent::paneId))
    }

    @Test
    fun `uses checkout path as skills root and ignores blank paths`() {
        assertEquals("/worktree", agent("idle", "1", checkoutPath = "/worktree").skillsProjectRoot)
        assertEquals("/project", agent("idle", "2", checkoutPath = "", cwd = "/project").skillsProjectRoot)
        assertNull(agent("idle", "3", checkoutPath = "", cwd = "").skillsProjectRoot)
    }

    private fun agent(
        status: String,
        paneId: String,
        checkoutPath: String? = null,
        cwd: String = "/project",
    ) = ConsoleAgent(
        hostId = "host",
        hostName = "Host",
        paneId = paneId,
        terminalId = "terminal-$paneId",
        kind = "codex",
        name = null,
        title = "",
        status = AgentStatus(status),
        workspaceId = "workspace",
        workspaceLabel = null,
        repoName = null,
        checkoutPath = checkoutPath,
        cwd = cwd,
        revision = 0,
        connectionGeneration = 1L,
    )
}
