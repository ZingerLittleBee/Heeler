import UserNotifications

/// The Notification Service Extension shell (ADR 0008). iOS hands every
/// `mutable-content` push through here before display; all real work — kid
/// key selection, envelope decryption, alert phrasing — is the pure
/// `AgentNotificationRenderer.alert` over the Notification Keys in the
/// shared-access-group Keychain, compiled from HeelerNotificationCore and
/// covered by the app test suite against the shared vectors. Undecryptable
/// pushes get the generic fallback copy applied unconditionally, so garbage
/// input never renders as-is and never crashes the extension.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = Self.rewritten(request.content)
        // Detailed alerts (#428): register a category whose one action names
        // the destination, then deliver. Default alerts skip this entirely.
        guard let actionTitle = content.alertActionTitle,
            let rewritten = content.content.mutableCopy() as? UNMutableNotificationContent
        else {
            contentHandler(content.content)
            return
        }
        let identifier = AgentNotificationDetail.categoryIdentifier(actionTitle: actionTitle)
        rewritten.categoryIdentifier = identifier
        let deliver = UncheckedSendable(contentHandler)
        let delivered = UncheckedSendable(rewritten)
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            let existing = Array(existing)
            let action = UNNotificationAction(
                identifier: AgentNotificationDetail.openAgentActionIdentifier,
                title: actionTitle, options: [.foreground])
            let added = UNNotificationCategory(
                identifier: identifier, actions: [action], intentIdentifiers: [])
            let byID = Dictionary(
                (existing + [added]).map { ($0.identifier, $0) }, uniquingKeysWith: { $1 })
            let kept = AgentNotificationDetail.mergedCategoryIdentifiers(
                existing: existing.map(\.identifier), adding: identifier
            ).compactMap { byID[$0] }
            UNUserNotificationCenter.current().setNotificationCategories(Set(kept))
            deliver.value(delivered.value)
        }
    }

    // Everything in didReceive is synchronous, so the expiration callback
    // can never catch it mid-flight; if iOS ever cut us off anyway, the
    // system falls back to the relay's generic wrap copy, which is the same
    // banner our own fallback shows. The Detailed alerts category lookup is
    // the one asynchronous step; it is a local call.
    override func serviceExtensionTimeWillExpire() {}

    private static func rewritten(_ content: UNNotificationContent) -> (
        content: UNNotificationContent, alertActionTitle: String?
    ) {
        let records = (try? NotificationKeyStore().allRecords()) ?? []
        let preferences = AgentNotificationDetailPreferences()
        let alert = AgentNotificationRenderer.alert(
            userInfo: content.userInfo, keys: records,
            detailed: { preferences.isEnabled(forHost: $0) })
        guard let rewritten = content.mutableCopy() as? UNMutableNotificationContent else {
            return (content, nil)
        }
        rewritten.title = alert.title
        // Cleared, not left alone: the relay's generic wrap may have set a
        // subtitle, and the decrypted copy has no use for one.
        rewritten.subtitle = ""
        rewritten.body = alert.body
        return (rewritten, alert.actionTitle)
    }
}

/// Carries UIKit's non-Sendable values into the categories callback; each is
/// used exactly once there.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
