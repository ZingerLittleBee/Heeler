import Foundation
import UserNotifications

/// Thin UNUserNotificationCenter delegate (#74). Every decision is pure and
/// unit-tested — `AgentNotificationRouting` resolves the push, the MainActor
/// `AgentNotificationRouter` holds the navigation state — because real iOS
/// notification presentation is not automatable (spec #68).
///
/// The completion-handler forms are deliberate: UIKit invokes these callbacks
/// on a background queue, and a background-tap completion drives
/// main-thread-only UIKit state restoration (SIGABRT otherwise). The async
/// forms hand the completion to whatever executor the continuation resumes
/// on, so only the handler forms let us pin it to the main thread. The push
/// is resolved on the callback queue; only the Sendable target crosses.
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
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions)
            -> Void
    ) {
        let target = AgentNotificationRouting.target(
            userInfo: notification.request.content.userInfo, keys: loadKeys())
        let complete = UncheckedSendable(completionHandler)
        Task { @MainActor [router] in
            complete.value(router.presentationOptions(for: target))
        }
    }

    /// A tap (the default action) deep-links to the Agent's Attach; explicit
    /// dismissal routes nowhere.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isDefaultTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let target: AgentNotificationTarget? =
            isDefaultTap
            ? AgentNotificationRouting.target(
                userInfo: response.notification.request.content.userInfo, keys: loadKeys())
            : nil
        let complete = UncheckedSendable(completionHandler)
        Task { @MainActor [router] in
            if isDefaultTap { router.open(target) }
            complete.value()
        }
    }
}

/// Carries UIKit's non-Sendable completion handlers to the main actor; each
/// is invoked exactly once there.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
