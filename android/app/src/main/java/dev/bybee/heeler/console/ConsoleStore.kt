package dev.bybee.heeler.console

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.bybee.heeler.connection.HostConnectionManager
import dev.bybee.heeler.connection.HostConnectionState
import dev.bybee.heeler.core.transport.Agent
import dev.bybee.heeler.core.transport.AgentLaunchRequest
import dev.bybee.heeler.core.transport.SupportedAgentKind
import dev.bybee.heeler.core.transport.WorktreeSpec
import dev.bybee.heeler.core.wire.AgentRenameParams
import dev.bybee.heeler.core.wire.PaneTarget
import dev.bybee.heeler.core.wire.WorkspaceRenameParams
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * The flat Console aggregate. Each Host has one [HostConsoleProjection]; this
 * store only aligns those projections with the Host catalog and publishes a
 * stable, status-sorted cross-Host view.
 */
class ConsoleStore(
    private val hostStore: HostStore,
    private val connections: HostConnectionManager,
) : ViewModel() {
    private val projections = mutableMapOf<String, HostConsoleProjection>()

    private val mutableAgents = MutableStateFlow<List<ConsoleAgent>>(emptyList())
    val agents: StateFlow<List<ConsoleAgent>> = mutableAgents.asStateFlow()

    private val mutableHostStates = MutableStateFlow<Map<String, HostConnectionState>>(emptyMap())
    val hostStates: StateFlow<Map<String, HostConnectionState>> = mutableHostStates.asStateFlow()

    private val mutableHostsAwaitingSnapshot = MutableStateFlow<Set<String>>(emptySet())
    val hostsAwaitingSnapshot: StateFlow<Set<String>> = mutableHostsAwaitingSnapshot.asStateFlow()

    private val mutableWorkspacesByHost = MutableStateFlow<Map<String, List<ConsoleWorkspace>>>(emptyMap())
    val workspacesByHost: StateFlow<Map<String, List<ConsoleWorkspace>>> = mutableWorkspacesByHost.asStateFlow()

    private val mutableSelectedHostId = MutableStateFlow<String?>(null)
    val selectedHostId: StateFlow<String?> = mutableSelectedHostId.asStateFlow()

    /** The flat list narrowed to an optional Host without changing sort semantics. */
    val visibleAgents: StateFlow<List<ConsoleAgent>> = combine(agents, selectedHostId) { all, hostId ->
        hostId?.let { selected -> all.filter { it.hostId == selected } } ?: all
    }.stateIn(viewModelScope, kotlinx.coroutines.flow.SharingStarted.Eagerly, emptyList())

    init {
        viewModelScope.launch {
            hostStore.hosts.collect(::reconcileHosts)
        }
    }

    fun selectHost(hostId: String?) {
        mutableSelectedHostId.value = hostId?.takeIf { selected ->
            hostStore.hosts.value.any { it.id == selected }
        }
    }

    /** Revalidates every Host and asks connected projections for a current snapshot. */
    suspend fun refresh() {
        connections.revalidateAll()
        projections.values.toList().forEach(HostConsoleProjection::refresh)
    }

    /** Refreshes exactly one Host without waiting for unrelated Host timeouts. */
    suspend fun refreshHost(hostId: String) {
        connections.reconnect(hostId)
        projections[hostId]?.refresh()
    }

    fun agent(hostId: String, paneId: String): ConsoleAgent? =
        mutableAgents.value.firstOrNull { it.hostId == hostId && it.paneId == paneId }

    fun workspaces(hostId: String): List<ConsoleWorkspace> =
        mutableWorkspacesByHost.value[hostId].orEmpty()

    suspend fun availableAgentKinds(hostId: String): List<SupportedAgentKind> =
        connections.transport(hostId).availableAgentKinds()

    suspend fun startAgent(hostId: String, request: AgentLaunchRequest): Agent {
        val agent = connections.transport(hostId).startAgent(request)
        projections[hostId]?.refresh()
        return agent
    }

    suspend fun startAgentInNewWorktree(
        hostId: String,
        request: AgentLaunchRequest,
        worktree: WorktreeSpec,
    ): Agent {
        val agent = connections.transport(hostId).startAgentInNewWorktree(request, worktree)
        projections[hostId]?.refresh()
        return agent
    }

    suspend fun closePane(hostId: String, paneId: String) {
        connections.transport(hostId).closePane(PaneTarget(paneID = paneId))
        projections[hostId]?.refresh()
    }

    suspend fun renameAgent(hostId: String, paneId: String, name: String?) {
        connections.transport(hostId).renameAgent(AgentRenameParams(target = paneId, name = name))
        projections[hostId]?.refresh()
    }

    suspend fun renameWorkspace(hostId: String, workspaceId: String, label: String) {
        connections.transport(hostId).renameWorkspace(
            WorkspaceRenameParams(label = label, workspaceID = workspaceId),
        )
        projections[hostId]?.refresh()
    }

    private fun reconcileHosts(hosts: List<Host>) {
        val incoming = hosts.associateBy(Host::id)
        projections.entries.iterator().let { entries ->
            while (entries.hasNext()) {
                val entry = entries.next()
                if (incoming[entry.key] == entry.value.host) continue
                entry.value.stop()
                entries.remove()
            }
        }
        hosts.forEach { host ->
            if (projections[host.id] != null) return@forEach
            projections[host.id] = HostConsoleProjection(
                host = host,
                connections = connections,
                scope = viewModelScope,
                onChange = ::rebuild,
            ).also(HostConsoleProjection::start)
        }
        if (mutableSelectedHostId.value?.let { it !in incoming } == true) {
            mutableSelectedHostId.value = null
        }
        rebuild()
    }

    private fun rebuild() {
        val current = projections.values.toList()
        mutableAgents.value = current.flatMap { it.agents.value.values }.consoleSorted()
        mutableWorkspacesByHost.value = current.associate { it.host.id to it.workspaces.value }
        mutableHostsAwaitingSnapshot.value = current
            .filter { it.isAwaitingSnapshot.value }
            .mapTo(linkedSetOf()) { it.host.id }
        mutableHostStates.value = current.associate { projection ->
            projection.host.id to connections.state(projection.host.id).value
        }
    }

    override fun onCleared() {
        projections.values.forEach(HostConsoleProjection::stop)
        projections.clear()
        super.onCleared()
    }
}
