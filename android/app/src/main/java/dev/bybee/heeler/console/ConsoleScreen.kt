package dev.bybee.heeler.console

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bybee.heeler.connection.HostConnectionState
import dev.bybee.heeler.core.transport.TransportError
import dev.bybee.heeler.core.transport.connectionGuidance
import dev.bybee.heeler.core.wire.AgentStatus
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostStore
import kotlinx.coroutines.launch

/** The Console home: a flat, status-sorted list of Agents across configured Hosts. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConsoleScreen(
    consoleStore: ConsoleStore,
    hostStore: HostStore,
    onOpenAgent: (hostId: String, paneId: String) -> Unit,
    onOpenHosts: () -> Unit,
    onAddHost: () -> Unit,
    onOpenSettings: () -> Unit,
    onStartAgent: (hostId: String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val hosts by hostStore.hosts.collectAsState()
    val agents by consoleStore.agents.collectAsState()
    val visibleAgents by consoleStore.visibleAgents.collectAsState()
    val hostsAwaitingSnapshot by consoleStore.hostsAwaitingSnapshot.collectAsState()
    val hostStates by consoleStore.hostStates.collectAsState()
    val selectedHostId by consoleStore.selectedHostId.collectAsState()
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Agents") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
                actions = {
                    IconButton(onClick = onOpenHosts) {
                        Icon(Icons.Outlined.Dns, contentDescription = "Hosts")
                    }
                    IconButton(onClick = onOpenSettings) {
                        Icon(Icons.Outlined.Settings, contentDescription = "Settings")
                    }
                    if (hosts.isNotEmpty()) {
                        IconButton(onClick = { onStartAgent(selectedHostId) }) {
                            Icon(Icons.Outlined.Add, contentDescription = "New Agent")
                        }
                    }
                },
            )
        },
    ) { contentPadding ->
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                scope.launch {
                    refreshing = true
                    try {
                        consoleStore.refresh()
                    } finally {
                        refreshing = false
                    }
                }
            },
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding),
        ) {
            if (hosts.isEmpty()) {
                NoHostsState(onAddHost)
            } else {
                ConsoleList(
                    hosts = hosts,
                    allAgents = agents,
                    visibleAgents = visibleAgents,
                    selectedHostId = selectedHostId,
                    hostStates = hostStates,
                    hostsAwaitingSnapshot = hostsAwaitingSnapshot,
                    onSelectHost = consoleStore::selectHost,
                    onOpenAgent = onOpenAgent,
                    onOpenHosts = onOpenHosts,
                )
            }
        }
    }
}

@Composable
private fun ConsoleList(
    hosts: List<Host>,
    allAgents: List<ConsoleAgent>,
    visibleAgents: List<ConsoleAgent>,
    selectedHostId: String?,
    hostStates: Map<String, HostConnectionState>,
    hostsAwaitingSnapshot: Set<String>,
    onSelectHost: (String?) -> Unit,
    onOpenAgent: (String, String) -> Unit,
    onOpenHosts: () -> Unit,
) {
    val visibleIssues = hosts.mapNotNull { host ->
        hostStates[host.id]?.consoleIssue(host)
    }.filter { issue -> selectedHostId == null || issue.host.id == selectedHostId }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (hosts.size > 1) {
            item(key = "host-filter") {
                HostFilter(
                    hosts = hosts,
                    selectedHostId = selectedHostId,
                    onSelectHost = onSelectHost,
                )
            }
        }
        items(visibleIssues, key = { "issue-${it.host.id}" }) { issue ->
            ConnectionIssueRow(issue, onOpenHosts)
        }
        when {
            allAgents.isEmpty() && hostsAwaitingSnapshot.isNotEmpty() -> item(key = "loading-agents") {
                EmptyConsoleState(
                    title = "Loading Agents",
                    message = "Connecting to your Hosts and syncing their Agents…",
                    action = "Manage Hosts",
                    onAction = onOpenHosts,
                )
            }
            allAgents.isEmpty() -> item(key = "no-agents") {
                NoAgentsState(
                    message = visibleIssues.firstOrNull()?.message
                        ?: "Agents detected on your Hosts appear here.",
                    onOpenHosts = onOpenHosts,
                )
            }
            visibleAgents.isEmpty() -> item(key = "no-filtered-agents") {
                NoAgentsState(
                    message = "No Agents on ${hosts.firstOrNull { it.id == selectedHostId }?.name ?: "this Host"}.",
                    onOpenHosts = onOpenHosts,
                    showAllHosts = { onSelectHost(null) },
                )
            }
            else -> items(visibleAgents, key = { "agent-${it.hostId}/${it.paneId}" }) { agent ->
                AgentCard(agent = agent, onClick = { onOpenAgent(agent.hostId, agent.paneId) })
            }
        }
    }
}

@Composable
private fun HostFilter(
    hosts: List<Host>,
    selectedHostId: String?,
    onSelectHost: (String?) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FilterChip(
            selected = selectedHostId == null,
            onClick = { onSelectHost(null) },
            label = { Text("All Hosts") },
            leadingIcon = {
                Icon(Icons.Outlined.Tune, contentDescription = null, modifier = Modifier.size(18.dp))
            },
        )
        hosts.forEach { host ->
            FilterChip(
                selected = selectedHostId == host.id,
                onClick = { onSelectHost(host.id) },
                label = { Text(host.name, maxLines = 1) },
            )
        }
    }
}

@Composable
fun AgentCard(
    agent: ConsoleAgent,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = agent.displayName,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val context = listOfNotNull(agent.workspaceLabel, agent.repoName).joinToString(" · ")
                    Text(
                        text = context.ifBlank { agent.hostName },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.width(12.dp))
                AgentStatusChip(agent.status)
            }
            if (agent.lastOutputSnippet != null) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Text(
                    text = agent.lastOutputSnippet,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            } else if (agent.title.isNotBlank()) {
                Text(
                    text = agent.title,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun AgentStatusChip(status: AgentStatus) {
    val label = when (status.rawValue) {
        AgentStatus.blocked.rawValue -> "Blocked"
        AgentStatus.done.rawValue -> "Done"
        AgentStatus.working.rawValue -> "Working"
        AgentStatus.idle.rawValue -> "Idle"
        else -> "Unknown"
    }
    val colors = when (status.rawValue) {
        AgentStatus.blocked.rawValue -> AssistChipDefaults.assistChipColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
            labelColor = MaterialTheme.colorScheme.onErrorContainer,
        )
        AgentStatus.done.rawValue -> AssistChipDefaults.assistChipColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer,
            labelColor = MaterialTheme.colorScheme.onSecondaryContainer,
        )
        AgentStatus.working.rawValue -> AssistChipDefaults.assistChipColors(
            containerColor = MaterialTheme.colorScheme.tertiaryContainer,
            labelColor = MaterialTheme.colorScheme.onTertiaryContainer,
        )
        else -> AssistChipDefaults.assistChipColors()
    }
    AssistChip(onClick = {}, label = { Text(label) }, colors = colors)
}

@Composable
private fun ConnectionIssueRow(issue: ConsoleIssue, onOpenHosts: () -> Unit) {
    OutlinedButton(
        onClick = onOpenHosts,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp),
    ) {
        Icon(
            Icons.Outlined.Refresh,
            contentDescription = null,
            tint = if (issue.critical) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.tertiary,
        )
        Spacer(Modifier.width(12.dp))
        Text(
            issue.message,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun NoHostsState(onAddHost: () -> Unit) {
    EmptyConsoleState(
        title = "No Hosts",
        message = "Add a Host that runs herdr to see its Agents here.",
        action = "Add Host",
        onAction = onAddHost,
    )
}

@Composable
private fun NoAgentsState(
    message: String,
    onOpenHosts: () -> Unit,
    showAllHosts: (() -> Unit)? = null,
) {
    EmptyConsoleState(
        title = "No Agents",
        message = message,
        action = "Manage Hosts",
        onAction = onOpenHosts,
        secondaryAction = showAllHosts?.let { "Show All Hosts" to it },
    )
}

@Composable
private fun EmptyConsoleState(
    title: String,
    message: String,
    action: String,
    onAction: () -> Unit,
    secondaryAction: Pair<String, () -> Unit>? = null,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(12.dp))
        Text(
            message,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(24.dp))
        Button(onClick = onAction) { Text(action) }
        secondaryAction?.let { (label, callback) ->
            OutlinedButton(onClick = callback, modifier = Modifier.padding(top = 8.dp)) { Text(label) }
        }
    }
}

private data class ConsoleIssue(
    val host: Host,
    val message: String,
    val critical: Boolean,
)

private fun HostConnectionState.consoleIssue(host: Host): ConsoleIssue? = when (this) {
    HostConnectionState.Connecting,
    HostConnectionState.Suspended -> null
    is HostConnectionState.Connected -> syncError?.let { message ->
        ConsoleIssue(host, "${host.name}: $message", critical = false)
    }
    is HostConnectionState.Reconnecting -> ConsoleIssue(
        host,
        "Reconnecting to ${host.name}: ${error.summary()}",
        critical = false,
    )
    is HostConnectionState.Failed -> ConsoleIssue(
        host,
        "${host.name}: ${error.connectionGuidance}",
        critical = error is TransportError.HostKeyMismatch || error is TransportError.HostKeyRejected,
    )
}

private fun TransportError.summary(): String = when (this) {
    is TransportError.SshUnreachable -> "SSH unavailable"
    TransportError.TimedOut -> "request timed out"
    TransportError.Cancelled -> "request was cancelled"
    is TransportError.ChannelFailed -> "connection dropped"
    is TransportError.ApiRejected -> "herdr rejected the request"
    else -> "connection failed"
}
