import Foundation
import UserNotifications

/// Thin UNUserNotificationCenter delegate (#74). Every decision is pure and
/// unit-tested — `AgentNotificationRouting` resolves the push,
/// `AgentDeepLinkPolicy` picks the window, and each window's MainActor
/// `AgentNotificationRouter` holds its navigation state — because real iOS
/// notification presentation is not automatable (spec #68).
///
/// The completion-handler forms are deliberate: UIKit invokes these callbacks
/// on a background queue, and the tap completion drives main-thread-only
/// UIKit state restoration (SIGABRT otherwise). The async forms hand the
/// completion to whatever executor the continuation resumes on, so only the
/// handler forms let us pin it to the main thread. The push is resolved on
/// the callback queue; only the Sendable target crosses.
final class AgentNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    private let directory: AgentSceneDirectory
    private let loadKeys: @Sendable () -> [NotificationKeyRecord]

    init(
        directory: AgentSceneDirectory,
        loadKeys: @escaping @Sendable () -> [NotificationKeyRecord] = {
            (try? NotificationKeyStore().allRecords()) ?? []
        }
    ) {
        self.directory = directory
        self.loadKeys = loadKeys
    }

    /// Foreground pushes never present (#77): while the app is foregrounded
    /// the live event stream announces transitions through the in-app banner
    /// (`AgentNotificationBannerStore`), so the system banner is fully
    /// silenced. Background and killed-state delivery is untouched —
    /// willPresent only runs for a foregrounded app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions)
            -> Void
    ) {
        completionHandler([])
    }

    /// A tap (the default action) deep-links to the Agent's Attach through
    /// the single-window rule; so does the Detailed alerts `Open …` action
    /// (#428), which only names the same destination. Explicit dismissal
    /// routes nowhere.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isDefaultTap =
            response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == AgentNotificationDetail.openAgentActionIdentifier
        let target: AgentNotificationTarget? =
            isDefaultTap
            ? AgentNotificationRouting.target(
                userInfo: response.notification.request.content.userInfo, keys: loadKeys())
            : nil
        let complete = UncheckedSendable(completionHandler)
        Task { @MainActor [directory] in
            if isDefaultTap { directory.open(target) }
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
