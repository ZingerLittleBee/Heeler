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
        contentHandler(Self.rewritten(request.content))
    }

    // Everything in didReceive is synchronous, so the expiration callback
    // can never catch it mid-flight; if iOS ever cut us off anyway, the
    // system falls back to the relay's generic wrap copy, which is the same
    // banner our own fallback shows.
    override func serviceExtensionTimeWillExpire() {}

    private static func rewritten(_ content: UNNotificationContent) -> UNNotificationContent {
        let records = (try? NotificationKeyStore().allRecords()) ?? []
        let alert = AgentNotificationRenderer.alert(userInfo: content.userInfo, keys: records)
        guard let rewritten = content.mutableCopy() as? UNMutableNotificationContent else {
            return content
        }
        rewritten.title = alert.title
        // Cleared, not left alone: the relay's generic wrap may have set a
        // subtitle, and the decrypted copy has no use for one.
        rewritten.subtitle = ""
        rewritten.body = alert.body
        return rewritten
    }
}
