package dev.bybee.heeler

import android.app.Activity
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Modifier
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import dev.bybee.heeler.console.ConsoleScreen
import dev.bybee.heeler.console.StartAgentScreen
import dev.bybee.heeler.detail.AgentDetailScreen
import dev.bybee.heeler.hosts.HostDetailScreen
import dev.bybee.heeler.hosts.HostFormScreen
import dev.bybee.heeler.hosts.HostsScreen
import dev.bybee.heeler.notifications.AgentNotificationBannerHost
import dev.bybee.heeler.pairing.PairingScannerScreen
import dev.bybee.heeler.settings.SettingsScreen
import dev.bybee.heeler.snippets.SnippetsManagementScreen
import dev.bybee.heeler.ui.theme.HeelerTheme
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect

class MainActivity : ComponentActivity() {
    private val container: AppContainer
        get() = (application as HeelerApplication).container

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        container.pendingNavigationStore.acceptIntent(intent)
        setContent {
            HeelerTheme {
                HeelerNavHost(container)
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        container.pendingNavigationStore.acceptIntent(intent)
    }
}

@Composable
private fun HeelerNavHost(container: AppContainer) {
    val navController = rememberNavController()
    val pendingNavigation = container.pendingNavigationStore
    val activity = LocalContext.current as? Activity

    BackHandler {
        pendingNavigation.onUserNavigation()
        if (!navController.popBackStack()) activity?.finish()
    }
    val agents by container.consoleStore.agents.collectAsState()

    LaunchedEffect(agents) {
        pendingNavigation.agentsDidChange(agents)
        container.notificationBannerStore.agentsDidChange(agents)
    }
    val navigator = container.navigator
    val entry by navController.currentBackStackEntryAsState()

    LaunchedEffect(pendingNavigation, navController) {
        launch {
            pendingNavigation.navigation.collect { route ->
                navController.navigate(route) { launchSingleTop = true }
            }
        }
        launch {
            navigator.routes.collect { route ->
                // Agent detail only emits this bridge in response to a user
                // selecting another Agent from its switcher.
                pendingNavigation.onUserNavigation()
                navController.navigate(route) { launchSingleTop = true }
            }
        }
    }
    LaunchedEffect(entry) {
        navigator.destinationChanged(entry?.actualRoute())
    }

    fun navigateUser(route: String) {
        pendingNavigation.onUserNavigation()
        navController.navigate(route) { launchSingleTop = true }
    }
    fun goBackUser() {
        pendingNavigation.onUserNavigation()
        navController.popBackStack()
    }

    Box(Modifier.fillMaxSize()) {
        NavHost(navController = navController, startDestination = Routes.CONSOLE) {
            composable(Routes.CONSOLE) {
                ConsoleScreen(
                    consoleStore = container.consoleStore,
                    hostStore = container.hostStore,
                    onOpenAgent = { hostId, paneId ->
                        navigateUser(Routes.agent(hostId, paneId))
                    },
                    onOpenHosts = { navigateUser(Routes.HOSTS) },
                    onAddHost = { navigateUser(Routes.NEW_HOST) },
                    onOpenSettings = { navigateUser(Routes.SETTINGS) },
                    onStartAgent = { hostId -> navigateUser(Routes.startAgent(hostId)) },
                )
            }
            composable(
                route = Routes.AGENT,
                arguments = listOf(
                    navArgument(Routes.HOST_ID) { type = NavType.StringType },
                    navArgument(Routes.PANE_ID) { type = NavType.StringType },
                ),
            ) { destination ->
                AgentDetailScreen(
                    hostId = destination.requiredArgument(Routes.HOST_ID),
                    paneId = destination.requiredArgument(Routes.PANE_ID),
                    onBack = ::goBackUser,
                )
            }
            composable(Routes.HOSTS) {
                HostsScreen(
                    hostStore = container.hostStore,
                    connections = container.connectionManager,
                    onOpenHost = { hostId -> navigateUser(Routes.host(hostId)) },
                    onAddHost = { navigateUser(Routes.NEW_HOST) },
                    onPairHost = { navigateUser(Routes.PAIRING) },
                    onBack = ::goBackUser,
                )
            }
            composable(Routes.NEW_HOST) {
                HostFormScreen(
                    hostStore = container.hostStore,
                    editing = null,
                    onSaved = { host -> navigateUser(Routes.host(host.id)) },
                    onCancel = ::goBackUser,
                )
            }
            composable(
                route = Routes.HOST,
                arguments = listOf(navArgument(Routes.HOST_ID) { type = NavType.StringType }),
            ) { destination ->
                HostDetailScreen(
                    hostId = destination.requiredArgument(Routes.HOST_ID),
                    hostStore = container.hostStore,
                    connections = container.connectionManager,
                    notificationStore = container.notificationRegistrationStore,
                    onBack = ::goBackUser,
                )
            }
            composable(Routes.PAIRING) {
                PairingScannerScreen(
                    hostStore = container.hostStore,
                    onHostPaired = { hostId -> navigateUser(Routes.host(hostId)) },
                    onBack = ::goBackUser,
                )
            }
            composable(
                route = Routes.START_AGENT,
                arguments = listOf(
                    navArgument(Routes.HOST_ID) {
                        type = NavType.StringType
                        nullable = true
                        defaultValue = null
                    },
                ),
            ) { destination ->
                StartAgentScreen(
                    consoleStore = container.consoleStore,
                    hostStore = container.hostStore,
                    initialHostId = destination.arguments?.getString(Routes.HOST_ID),
                    onStarted = { hostId, paneId -> navigateUser(Routes.agent(hostId, paneId)) },
                    onBack = ::goBackUser,
                )
            }
            composable(Routes.SETTINGS) {
                SettingsScreen(
                    appearanceStore = container.terminalAppearanceStore,
                    relaySettings = container.relaySettings,
                    onClose = ::goBackUser,
                )
            }
            composable(Routes.SNIPPETS) {
                SnippetsManagementScreen(store = container.snippetStore, onClose = ::goBackUser)
            }
        }
        AgentNotificationBannerHost(
            store = container.notificationBannerStore,
            onOpenAgent = { target ->
                pendingNavigation.onUserNavigation()
                navController.navigate(Routes.agent(target.hostId, target.paneId)) {
                    launchSingleTop = true
                }
            },
        )
    }
}

private object Routes {
    const val CONSOLE = "console"
    const val HOSTS = "hosts"
    const val PAIRING = "pairing"
    const val SETTINGS = "settings"
    const val SNIPPETS = "snippets"
    const val HOST_ID = "hostId"
    const val PANE_ID = "paneId"
    const val AGENT = "agent/{$HOST_ID}/{$PANE_ID}"
    const val HOST = "host/{$HOST_ID}"
    const val NEW_HOST = "host/new"
    const val START_AGENT = "startAgent?hostId={$HOST_ID}"

    fun agent(hostId: String, paneId: String): String =
        "agent/${Uri.encode(hostId)}/${Uri.encode(paneId)}"

    fun host(hostId: String): String = "host/${Uri.encode(hostId)}"

    fun startAgent(hostId: String?): String = hostId?.let {
        "startAgent?hostId=${Uri.encode(it)}"
    } ?: "startAgent"
}

private fun NavBackStackEntry.actualRoute(): String? {
    val route = destination.route ?: return null
    if (route != Routes.AGENT) return route
    val hostId = arguments?.getString(Routes.HOST_ID) ?: return null
    val paneId = arguments?.getString(Routes.PANE_ID) ?: return null
    return Routes.agent(hostId, paneId)
}

private fun NavBackStackEntry.requiredArgument(name: String): String =
    requireNotNull(arguments?.getString(name)) { "Missing navigation argument $name." }
