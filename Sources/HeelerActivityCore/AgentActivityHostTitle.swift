import Foundation

/// Lock-screen / Dynamic Island header title for a decrypted Live Activity.
///
/// The widget prefers the Host name captured at Notification Registration
/// (the `NotificationKeyRecord` selected by envelope `kid`). Envelope `host`
/// is only a defensive fallback: a successful kid-keyed decrypt implies a
/// record, so this path is not expected in production. The wire field stays.
enum AgentActivityHostTitle {
    static func resolved(registeredName: String?, envelopeName: String) -> String {
        if let registeredName, !registeredName.isEmpty { return registeredName }
        return envelopeName
    }
}
