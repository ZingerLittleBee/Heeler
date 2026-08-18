package dev.bybee.heeler

import android.content.Context
import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import dev.bybee.heeler.connection.HostConnectionManager
import dev.bybee.heeler.console.ConsoleStore
import dev.bybee.heeler.core.crypto.DeviceKeyStore
import dev.bybee.heeler.core.transport.SharedPreferencesKnownHostsStore
import dev.bybee.heeler.data.HostStore
import dev.bybee.heeler.notifications.AgentNotificationBannerStore
import dev.bybee.heeler.notifications.NotificationRegistrationStore
import dev.bybee.heeler.notifications.NotificationRelaySettings
import dev.bybee.heeler.settings.TerminalAppearanceStore
import dev.bybee.heeler.snippets.SnippetStore
import dev.bybee.heeler.notifications.NotificationTransportProvider
import dev.bybee.heeler.notifications.PendingNavigationStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
/** Application composition root. Dependencies are explicit; no service locator or Hilt graph. */
class HeelerApplication : Application(), DefaultLifecycleObserver {
    private lateinit var appContainer: AppContainer

    /** The process-wide manual dependency container, available after [onCreate]. */
    val container: AppContainer
        get() = appContainer

    override fun onCreate() {
        super<Application>.onCreate()
        appContainer = AppContainer(this)
        ProcessLifecycleOwner.get().lifecycle.addObserver(this)
    }

    override fun onStart(owner: LifecycleOwner) {
        appContainer.connectionManager.onForeground()
    }

    override fun onStop(owner: LifecycleOwner) {
        appContainer.connectionManager.onBackground()
    }
}

class AppContainer(application: Application) {
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val hostStore = HostStore(application)
    private val deviceKeyStore = DeviceKeyStore.create(application)
    private val knownHosts = SharedPreferencesKnownHostsStore(
        application.getSharedPreferences("heeler-known-hosts", Context.MODE_PRIVATE),
    )
    val connectionManager = HostConnectionManager(
        hostStore = hostStore,
        deviceKeyStore = deviceKeyStore,
        knownHosts = knownHosts,
        scope = applicationScope,
    )
    val consoleStore = ConsoleStore(hostStore, connectionManager)
    val navigator = AppNavigator()
    val terminalAppearanceStore = TerminalAppearanceStore(application)
    val snippetStore = SnippetStore(application)
    val pendingNavigationStore = PendingNavigationStore()
    val relaySettings = NotificationRelaySettings(application)
    val notificationRegistrationStore = NotificationRegistrationStore(
        appContext = application,
        transports = NotificationTransportProvider { hostId -> connectionManager.transport(hostId) },
        relaySettings = relaySettings,
    )
    val notificationBannerStore = AgentNotificationBannerStore(
        presentedAgent = { navigator.presentedAgent.value },
        triggers = notificationRegistrationStore::confirmedTriggers,
    )
}
