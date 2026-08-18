package dev.bybee.heeler.notifications

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Host-detail notification controls. The Firebase prerequisite gets clear
 * user-facing copy instead of ever touching Firebase when unconfigured.
 */
@Composable
fun NotificationRegistrationSection(
    hostId: String,
    hostName: String,
    store: NotificationRegistrationStore,
    modifier: Modifier = Modifier,
) {
    val readiness by store.pushReadiness.collectAsState()
    val hostStates by store.hostStates.collectAsState()
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
        store::onNotificationPermissionResult,
    )

    LaunchedEffect(hostId, readiness) {
        if (readiness is PushReadiness.Ready) store.refreshHost(hostId)
    }

    Card(modifier = modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Agent notifications", style = MaterialTheme.typography.titleMedium)
            when (val push = readiness) {
                PushReadiness.Loading -> Text("Preparing Firebase Messaging…")
                PushReadiness.MissingFirebaseConfiguration -> {
                    Text(
                        "Firebase Messaging is not configured. Add google-services.json to android/app, then rebuild Heeler.",
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                is PushReadiness.Unavailable -> Text(push.message, color = MaterialTheme.colorScheme.error)
                is PushReadiness.Ready -> when (push.permission) {
                    NotificationPermissionState.Granted -> HostNotificationSettings(
                        state = hostStates[hostId],
                        onRefresh = { store.refreshHost(hostId) },
                        onEnabledChange = { enabled -> store.setEnabled(hostId, hostName, enabled) },
                        onDoneChange = { enabled -> store.setDoneEnabled(hostId, hostName, enabled) },
                    )
                    NotificationPermissionState.NeedsRequest,
                    NotificationPermissionState.Denied -> {
                        Text("Allow notifications to receive agent updates on this device.")
                        Button(onClick = { permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) }) {
                            Text("Allow notifications")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HostNotificationSettings(
    state: NotificationHostState?,
    onRefresh: () -> Unit,
    onEnabledChange: (Boolean) -> Unit,
    onDoneChange: (Boolean) -> Unit,
) {
    when (state) {
        null, NotificationHostState.Loading -> Text("Checking this Host’s notification settings…")
        is NotificationHostState.Unavailable -> {
            Text(state.message, color = MaterialTheme.colorScheme.error)
            OutlinedButton(onClick = onRefresh) { Text("Try again") }
        }
        is NotificationHostState.Idle -> NotificationToggles(
            settings = state.settings,
            enabled = true,
            onEnabledChange = onEnabledChange,
            onDoneChange = onDoneChange,
        )
        is NotificationHostState.Updating -> NotificationToggles(
            settings = state.settings,
            enabled = false,
            onEnabledChange = onEnabledChange,
            onDoneChange = onDoneChange,
        )
        is NotificationHostState.Failed -> {
            Text(state.message, color = MaterialTheme.colorScheme.error)
            NotificationToggles(
                settings = state.settings,
                enabled = true,
                onEnabledChange = onEnabledChange,
                onDoneChange = onDoneChange,
            )
        }
    }
}

@Composable
private fun NotificationToggles(
    settings: NotificationHostSettings,
    enabled: Boolean,
    onEnabledChange: (Boolean) -> Unit,
    onDoneChange: (Boolean) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f)) {
            Text("Notify this device")
            Text("Blocked and completed agents", style = MaterialTheme.typography.bodySmall)
        }
        Switch(
            checked = settings.registered,
            onCheckedChange = onEnabledChange,
            enabled = enabled,
        )
    }
    if (settings.registered) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Done")
                Text("Notify when an agent completes", style = MaterialTheme.typography.bodySmall)
            }
            Switch(
                checked = settings.preferences.done,
                onCheckedChange = onDoneChange,
                enabled = enabled,
            )
        }
    }
}
