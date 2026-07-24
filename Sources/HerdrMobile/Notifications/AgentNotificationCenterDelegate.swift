import Foundation
import UserNotifications

/// Thin UNUserNotificationCenter delegate (#74). Every decision is pure and
/// unit-tested — `AgentNotificationRouting` resolves the push, the MainActor
/// `AgentNotificationRouter` holds the navigation state — because real iOS
/// notification presentation is not automatable (spec #68). This shim only
/// resolves the push on the delegate's queue and hands the Sendable target
/// across.
///
/// All stored state is immutable and Sendable; the unchecked conformance
/// only bridges NSObject's lack of one.
final class AgentNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    private let router: AgentNotificationRouter
    private let loadKeys: @Sendable () -> [NotificationKeyRecord]

    init(
        router: AgentNotificationRouter,
        loadKeys: @escaping @Sendable () -> [NotificationKeyRecord] = {
            (try? NotificationKeyStore().allRecords()) ?? []
        }
    ) {
        self.router = router
        self.loadKeys = loadKeys
    }

    /// Foreground pushes: the banner shows unless the user is already
    /// viewing that exact Agent, decided at presentation time.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let target = AgentNotificationRouting.target(
            userInfo: notification.request.content.userInfo, keys: loadKeys())
        return await router.presentationOptions(for: target)
    }

    /// A tap (the default action) deep-links to the Agent's Attach; explicit
    /// dismissal routes nowhere.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let target = AgentNotificationRouting.target(
            userInfo: response.notification.request.content.userInfo, keys: loadKeys())
        await router.open(target)
    }
}
