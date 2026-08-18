package dev.bybee.heeler.console

import dev.bybee.heeler.connection.HostConnectionManager
import dev.bybee.heeler.connection.HostConnectionState
import dev.bybee.heeler.connection.HostConnectionUpdate
import dev.bybee.heeler.core.transport.Agent
import dev.bybee.heeler.core.transport.EventSubscription
import dev.bybee.heeler.core.transport.EventsSessionStatus
import dev.bybee.heeler.core.transport.EventsSessionUpdate
import dev.bybee.heeler.core.transport.GlobalEventKind
import dev.bybee.heeler.core.transport.HerdrEvent
import dev.bybee.heeler.core.transport.HerdrEventKind
import dev.bybee.heeler.core.transport.PaneEventKind
import dev.bybee.heeler.core.wire.AgentStatus
import dev.bybee.heeler.core.wire.PaneReadParams
import dev.bybee.heeler.core.wire.ReadSource
import dev.bybee.heeler.data.Host
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import java.util.Locale
import kotlinx.serialization.json.jsonPrimitive

/**
 * Snapshot-then-delta convergence for one Host. Membership changes initiate a
 * fresh snapshot; pane status events are applied immediately, then preserved
 * across an in-flight snapshot using a monotonically increasing revision.
 */
internal class HostConsoleProjection(
    val host: Host,
    private val connections: HostConnectionManager,
    private val scope: CoroutineScope,
    private val onChange: () -> Unit,
) {
    private val mutableAgents = MutableStateFlow<Map<String, ConsoleAgent>>(emptyMap())
    val agents: StateFlow<Map<String, ConsoleAgent>> = mutableAgents.asStateFlow()

    private val mutableWorkspaces = MutableStateFlow<List<ConsoleWorkspace>>(emptyList())
    val workspaces: StateFlow<List<ConsoleWorkspace>> = mutableWorkspaces.asStateFlow()

    private val mutableAwaitingSnapshot = MutableStateFlow(true)
    val isAwaitingSnapshot: StateFlow<Boolean> = mutableAwaitingSnapshot.asStateFlow()

    private var updatesJob: Job? = null
    private var connectionStateJob: Job? = null
    private var resyncJob: Job? = null
    private var retryJob: Job? = null
    private var resyncPending = false
    private var activeGeneration = 0L
    private var snapshotEpoch = 0L
    private var statusRevision = 0L
    private val statusChanges = mutableMapOf<String, StatusChange>()
    private val snippetJobs = mutableMapOf<String, Job>()
    private val pendingSnippetRefreshes = mutableSetOf<String>()
    private var ended = false

    fun start() {
        updatesJob = scope.launch {
            connections.events(host.id).collect(::handleUpdate)
        }
        connectionStateJob = scope.launch {
            connections.state(host.id).collect { state ->
                when (state) {
                    is HostConnectionState.Connected -> Unit
                    is HostConnectionState.Failed -> invalidateSnapshot(awaitingSnapshot = false)
                    else -> invalidateSnapshot()
                }
                onChange()
            }
        }
    }

    fun stop() {
        if (ended) return
        ended = true
        updatesJob?.cancel()
        connectionStateJob?.cancel()
        resyncJob?.cancel()
        retryJob?.cancel()
        snippetJobs.values.forEach(Job::cancel)
        snippetJobs.clear()
        pendingSnippetRefreshes.clear()
    }

    fun refresh() {
        if (connections.state(host.id).value is HostConnectionState.Connected) scheduleResync()
    }

    private fun handleUpdate(update: HostConnectionUpdate) {
        if (ended) return
        when (val sessionUpdate = update.update) {
            is EventsSessionUpdate.Status -> handleStatus(update.generation, sessionUpdate.status)
            is EventsSessionUpdate.Event -> handleEvent(update.generation, sessionUpdate.event)
        }
    }

    private fun handleStatus(generation: Long, status: EventsSessionStatus) {
        when (status) {
            EventsSessionStatus.Connected -> {
                if (generation < activeGeneration) return
                activeGeneration = generation
                scheduleResync()
            }
            is EventsSessionStatus.Failed -> invalidateSnapshot(awaitingSnapshot = false)
            is EventsSessionStatus.Reconnecting,
            EventsSessionStatus.Suspended,
            EventsSessionStatus.Ended -> invalidateSnapshot()
        }
        onChange()
    }

    private fun handleEvent(generation: Long, event: HerdrEvent) {
        if (generation != activeGeneration || ended) return
        when {
            event.kind == PaneEventKind.AGENT_STATUS_CHANGED.kind -> {
                val changedStatus = applyStatusChange(event.data as? JsonObject)
                if (changedStatus?.rawValue == AgentStatus.unknown.rawValue) scheduleResync()
            }
            event.kind in resyncEventKinds -> scheduleResync()
        }
    }

    /** One resync at a time; signals arriving mid-snapshot coalesce once. */
    private fun scheduleResync() {
        if (ended || connections.state(host.id).value !is HostConnectionState.Connected) return
        if (resyncJob?.isActive == true) {
            resyncPending = true
            return
        }
        val requestedGeneration = activeGeneration
        resyncJob = scope.launch {
            runResync(requestedGeneration)
            if (ended) return@launch
            resyncJob = null
            if (resyncPending) {
                resyncPending = false
                scheduleResync()
            }
        }
    }

    private suspend fun runResync(expectedGeneration: Long) {
        val epochBeforeSnapshot = snapshotEpoch
        val revisionBeforeSnapshot = statusRevision
        try {
            val snapshot = connections.transport(host.id).sessionSnapshot()
            if (!isCurrentSnapshot(expectedGeneration, epochBeforeSnapshot)) return
            retryJob?.cancel()
            retryJob = null
            connections.setSyncError(host.id, expectedGeneration, null)
            applySnapshot(snapshot.agents.map { Agent.fromWire(it) }, snapshot.workspaces, revisionBeforeSnapshot)
            connections.updateSubscriptions(host.id, subscriptions(mutableAgents.value.keys))
            refreshSnippets(expectedGeneration)
        } catch (_: Throwable) {
            if (!isCurrentSnapshot(expectedGeneration, epochBeforeSnapshot)) return
            connections.setSyncError(
                host.id,
                expectedGeneration,
                "Could not sync this Host's Agents. Retrying…",
            )
            scheduleRetry()
        }
    }

    private fun isCurrentSnapshot(expectedGeneration: Long, expectedEpoch: Long): Boolean =
        !ended &&
            expectedGeneration == activeGeneration &&
            expectedGeneration == connections.generation(host.id) &&
            expectedEpoch == snapshotEpoch &&
            connections.state(host.id).value is HostConnectionState.Connected

    private fun scheduleRetry() {
        if (retryJob?.isActive == true || ended) return
        retryJob = scope.launch {
            delay(SNAPSHOT_RETRY_MILLIS)
            retryJob = null
            scheduleResync()
        }
    }

    private fun invalidateSnapshot(awaitingSnapshot: Boolean = true) {
        snapshotEpoch += 1L
        mutableAwaitingSnapshot.value = awaitingSnapshot
        resyncPending = false
        retryJob?.cancel()
        retryJob = null
        statusChanges.clear()
        pendingSnippetRefreshes.clear()
        snippetJobs.values.forEach(Job::cancel)
        snippetJobs.clear()
        mutableAgents.value = emptyMap()
        mutableWorkspaces.value = emptyList()
    }

    private fun applySnapshot(
        agents: List<Agent>,
        workspaces: List<dev.bybee.heeler.core.wire.WorkspaceInfo>,
        revisionBeforeSnapshot: Long,
    ) {
        val workspaceById = workspaces.associateBy { it.workspaceID }
        val previousAgents = mutableAgents.value
        val nextAgents = agents.associate { agent ->
            val workspace = workspaceById[agent.workspaceID]
            agent.paneID to ConsoleAgent.fromAgent(
                hostId = host.id,
                hostName = host.name,
                agent = agent,
                workspaceLabel = workspace?.label,
                repoName = workspace?.worktree?.repoName,
                checkoutPath = workspace?.worktree?.checkoutPath,
                lastOutputSnippet = previousAgents[agent.paneID]?.lastOutputSnippet,
                connectionGeneration = activeGeneration,
            )
        }.toMutableMap()
        statusChanges.forEach { (paneId, change) ->
            if (change.revision > revisionBeforeSnapshot) {
                val row = nextAgents[paneId] ?: return@forEach
                nextAgents[paneId] = row.copy(status = change.status)
            }
        }
        statusChanges.clear()
        mutableAwaitingSnapshot.value = false
        mutableAgents.value = nextAgents
        mutableWorkspaces.value = workspaces
            .map { ConsoleWorkspace(it.workspaceID, it.label) }
            .sortedBy { it.label.lowercase(Locale.ROOT) }
        onChange()
    }

    private fun applyStatusChange(data: JsonObject?): AgentStatus? {
        val paneId = data?.get("pane_id")?.jsonPrimitive?.contentOrNull ?: return null
        val rawStatus = data["agent_status"]?.jsonPrimitive?.contentOrNull ?: return null
        val status = AgentStatus(rawStatus)
        statusRevision += 1L
        statusChanges[paneId] = StatusChange(statusRevision, status)
        mutableAgents.value[paneId]?.let { row ->
            mutableAgents.value = mutableAgents.value + (paneId to row.copy(status = status))
            refreshSnippet(paneId, activeGeneration)
            onChange()
        }
        return status
    }

    private fun refreshSnippets(expectedGeneration: Long) {
        mutableAgents.value.keys.forEach { paneId -> refreshSnippet(paneId, expectedGeneration) }
    }

    private fun refreshSnippet(paneId: String, expectedGeneration: Long) {
        if (snippetJobs[paneId]?.isActive == true) {
            pendingSnippetRefreshes += paneId
            return
        }
        val expectedEpoch = snapshotEpoch
        snippetJobs[paneId] = scope.launch {
            val snippet = try {
                val text = connections.transport(host.id).readPane(
                    PaneReadParams(
                        paneID = paneId,
                        source = ReadSource.recent,
                        lines = SNIPPET_READ_LINES,
                        stripANSI = true,
                    ),
                ).text
                snippetFrom(text)
            } catch (_: Throwable) {
                null
            }
            snippetJobs.remove(paneId)
            if (isCurrentSnapshot(expectedGeneration, expectedEpoch)) {
                mutableAgents.value[paneId]?.let { row ->
                    mutableAgents.value = mutableAgents.value + (paneId to row.copy(lastOutputSnippet = snippet))
                    onChange()
                }
            }
            if (pendingSnippetRefreshes.remove(paneId) && mutableAgents.value.containsKey(paneId)) {
                refreshSnippet(paneId, activeGeneration)
            }
        }
    }

    private data class StatusChange(val revision: Long, val status: AgentStatus)

    companion object {
        private const val SNIPPET_READ_LINES = 6
        private const val SNAPSHOT_RETRY_MILLIS = 2_000L

        private val membershipKinds = listOf(
            GlobalEventKind.PANE_AGENT_DETECTED,
            GlobalEventKind.PANE_CLOSED,
            GlobalEventKind.PANE_EXITED,
            GlobalEventKind.WORKSPACE_CREATED,
            GlobalEventKind.WORKSPACE_RENAMED,
            GlobalEventKind.WORKSPACE_METADATA_UPDATED,
            GlobalEventKind.WORKSPACE_CLOSED,
        )
        private val resyncEventKinds = membershipKinds.map(GlobalEventKind::kind).toSet() +
            HerdrEventKind.eventsDropped

        fun subscriptions(paneIds: Collection<String>): List<EventSubscription> =
            membershipKinds.map { EventSubscription.Global(it) } +
                paneIds.sorted().map { EventSubscription.Pane(PaneEventKind.AGENT_STATUS_CHANGED, it) }

        fun snippetFrom(text: String): String? = text.lineSequence()
            .map(String::trim)
            .lastOrNull(String::isNotEmpty)
    }
}
