import Foundation

/// The Agent Notification trust story (ADR 0008, #76) as plain strings, shared
/// by the pre-permission explainer and the persistent settings privacy section
/// so both surfaces tell exactly the same story. Kept as data — not buried in a
/// View — so a test can pin the load-bearing claims: it is a *push relay*
/// (never a "server"), it sees the device token, ciphertext, and source IP, and
/// it cannot see the decrypted content (agent names, statuses, pane ids); a
/// custom relay only helps a self-built app. All copy is English by project
/// convention.
enum NotificationPrivacyCopy {
    /// The explainer's lead line before the iOS permission prompt.
    static let explainerTitle = "Before you turn on notifications"

    /// The pipeline in one sentence, for the top of both surfaces.
    static let summary =
        "Agent Notifications travel through a push relay: your Host encrypts each "
        + "notification and the relay forwards it to Apple without ever holding the key "
        + "to read it."

    /// What the relay can see — the fields that cross it in the clear.
    static let relaySeesTitle = "What the push relay sees"
    static let relaySees: [String] = [
        "Your device's Apple push token, so Apple knows which device to notify.",
        "The encrypted notification (ciphertext), which it forwards without decrypting.",
        "Your Host's source IP address, as with any network request.",
    ]

    /// What the relay cannot see — the encrypted content it never holds a key
    /// for. Names the exact plaintext fields so the claim is concrete.
    static let relayCannotSeeTitle = "What it cannot see"
    static let relayCannotSee: [String] = [
        "The decrypted notification content: agent names, statuses, and pane ids.",
        "Anything about what your agents are doing — it never holds your Notification Key.",
    ]

    /// The self-built-app caveat for the custom relay setting.
    static let customRelayCaveat =
        "A custom relay only helps if you build the app yourself with your own bundle id "
        + "and Apple push key: push keys are bound to the app's bundle id, so this build can "
        + "only reach the developer-hosted relay."

    /// The primary action label on the explainer sheet, right before the iOS
    /// permission prompt appears.
    static let explainerConfirm = "Continue"
    /// The dismissive action label on the explainer sheet.
    static let explainerCancel = "Not Now"

    /// The GitHub-hosted `PRIVACY.md` the settings section links to.
    static let privacyPolicyURL = URL(
        string: "https://github.com/zinger-labs/herdr-mobile/blob/main/PRIVACY.md")!
}
