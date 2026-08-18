package dev.bybee.heeler.hosts

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.lifecycle.ViewModelProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.bybee.heeler.connection.HostConnectionManager
import dev.bybee.heeler.connection.HostConnectionState
import dev.bybee.heeler.data.Host
import dev.bybee.heeler.data.HostStore
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Host catalog for the `hosts` route. Rows expose status/latency but never connection guidance. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostsScreen(
    hostStore: HostStore,
    connections: HostConnectionManager,
    onOpenHost: (hostId: String) -> Unit,
    onAddHost: () -> Unit,
    onPairHost: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val viewModel: HostsViewModel = viewModel(
        key = "hosts-${hostStore.hashCode()}",
        factory = remember(hostStore, connections) { HostsViewModelFactory(hostStore, connections) },
    )
    val hosts by viewModel.hosts.collectAsState()
    var pendingRemoval by remember { mutableStateOf<Host?>(null) }
    pendingRemoval?.let { host ->
        AlertDialog(
            onDismissRequest = { pendingRemoval = null },
            title = { Text("Remove ${host.name}?") },
            text = { Text("This permanently deletes the Host configuration and saved password. This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    pendingRemoval = null
                    viewModel.remove(host.id)
                }) { Text("Remove") }
            },
            dismissButton = { TextButton(onClick = { pendingRemoval = null }) { Text("Cancel") } },
        )
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Hosts") },
                navigationIcon = { TextButton(onClick = onBack) { Text("Close") } },
                actions = {
                    TextButton(onClick = onPairHost) { Text("Pair") }
                    TextButton(onClick = onAddHost) { Text("Add") }
                },
            )
        },
        floatingActionButton = { FloatingActionButton(onClick = onAddHost) { Text("Add") } },
    ) { padding ->
        if (hosts.isEmpty()) {
            Column(
                modifier = Modifier.fillMaxSize().padding(padding).padding(32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("No Hosts yet", style = MaterialTheme.typography.headlineSmall)
                Text("Pair a computer or add its SSH details manually.")
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 20.dp)) {
                    Button(onClick = onPairHost) { Text("Pair") }
                    TextButton(onClick = onAddHost) { Text("Add manually") }
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(hosts, key = Host::id) { host ->
                    val connectionState by viewModel.connectionState(host.id).collectAsState()
                    HostRow(
                        host = host,
                        connectionState = connectionState,
                        onOpen = { onOpenHost(host.id) },
                        onReconnect = { viewModel.reconnect(host.id) },
                        onRemove = { pendingRemoval = host },
                    )
                }
            }
        }
    }
}

@Composable
private fun HostRow(
    host: Host,
    connectionState: HostConnectionState,
    onOpen: () -> Unit,
    onReconnect: () -> Unit,
    onRemove: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Card(onClick = onOpen, modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(host.name, style = MaterialTheme.typography.titleMedium)
                Text(
                    "${host.username}@${host.address}:${host.port}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                host.jumpHost?.let {
                    Text(
                        "via ${it.username}@${it.address}:${it.port}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            HostStatusChip(connectionState)
            Column(horizontalAlignment = Alignment.End) {
                TextButton(onClick = { menuOpen = true }) { Text("More") }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("Reconnect") },
                        onClick = { menuOpen = false; onReconnect() },
                    )
                    DropdownMenuItem(
                        text = { Text("Remove") },
                        onClick = { menuOpen = false; onRemove() },
                    )
                }
            }
        }
    }
}

/** The Hosts-row status presentation intentionally does not show `connectionGuidance`. */
@Composable
private fun HostStatusChip(state: HostConnectionState) {
    val text = when (state) {
        HostConnectionState.Connecting -> "Connecting…"
        is HostConnectionState.Connected -> state.latencyMillis?.let { "$it ms" } ?: "Connected"
        is HostConnectionState.Reconnecting -> "Reconnecting…"
        is HostConnectionState.Failed -> "Unavailable"
        HostConnectionState.Suspended -> "Suspended"
    }
    AssistChip(onClick = {}, label = { Text(text) }, modifier = Modifier.widthIn(max = 128.dp))
}

private class HostsViewModel(
    private val hostStore: HostStore,
    private val connections: HostConnectionManager,
) : ViewModel() {
    val hosts: StateFlow<List<Host>> = hostStore.hosts

    fun connectionState(hostId: String): StateFlow<HostConnectionState> = connections.state(hostId)

    fun reconnect(hostId: String) {
        viewModelScope.launch { connections.reconnect(hostId) }
    }

    fun remove(hostId: String) {
        viewModelScope.launch {
            hostStore.remove(hostId)
            connections.close(hostId)
        }
    }
}

private class HostsViewModelFactory(
    private val hostStore: HostStore,
    private val connections: HostConnectionManager,
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        HostsViewModel(hostStore, connections) as T
}
