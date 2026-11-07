import Foundation

/// The Agent Notification trust story (ADR 0008, #76) as plain strings, shared
/// by the pre-permission explainer and the persistent settings privacy section
/// so both surfaces tell exactly the same story. Kept as data — not buried in a
/// View — so a test can pin the load-bearing claims: it is a *push relay*
/// (never a "server"), it sees the device token, ciphertext, source IP, and
/// request timing, and the Live Activity fields APNs needs in cleartext. It
/// cannot see the encrypted identifying content (project, task, agent type,
/// Host, or pane id); a custom relay only helps a self-built app. Each string
/// is localized; the tests pin the English source.
enum NotificationPrivacyCopy {
    /// The explainer's lead line before the iOS permission prompt.
    static let explainerTitle = String(localized: "Before you turn on notifications")

    /// The pipeline in one sentence, for the top of both surfaces.
    static let summary =
        String(localized: "Agent Notifications travel through a push relay: your Host encrypts each notification and the relay forwards it to Apple without ever holding the key to read it.")

    /// What the relay can see — the fields that cross it in the clear.
    static let relaySeesTitle = String(localized: "What the push relay sees")
    static let relaySees: [String] = [
        String(localized: "Your device's Apple push token, so Apple knows which device to notify."),
        String(localized: "The encrypted notification (ciphertext), which it forwards without decrypting."),
        String(localized: "Your Host's source IP address, as with any network request."),
        String(localized: "When and how often your Host sends notification requests."),
        String(localized: "For Live Activities: aggregate status counts, the update or end event, priority, and event timing required by Apple."),
    ]

    /// What the relay cannot see — the encrypted content it never holds a key
    /// for. Names the exact encrypted fields so the claim is concrete.
    static let relayCannotSeeTitle = String(localized: "What it cannot see")
    static let relayCannotSee: [String] = [
        String(localized: "The identifying notification details: project name, task title, agent type and name, Host name, pane ID, and per-agent details."),
        String(localized: "The relay cannot decrypt this content because it never receives your Notification Key."),
    ]

    /// The self-built-app caveat for the custom relay setting.
    static let customRelayCaveat =
        String(localized: "A custom relay only works with an app you build and sign yourself. It must use APNs credentials authorized for that app's bundle ID. Only the developer-hosted relay is configured to deliver notifications to this App Store or TestFlight build.")

    /// The primary action label on the explainer sheet, right before the iOS
    /// permission prompt appears.
    static let explainerConfirm = String(localized: "Continue")
    /// The dismissive action label on the explainer sheet.
    static let explainerCancel = String(localized: "Not Now")

    /// The GitHub-hosted `PRIVACY.md` the settings section links to. Optional,
    /// like every `URL(string:)` in the app (no force unwraps); a link that
    /// depends on it simply hides if the constant ever fails to parse.
    static let privacyPolicyURL = URL(
        string: "https://github.com/ZingerLittleBee/Heeler/blob/main/PRIVACY.md")

    /// Per-Host Live Activity toggle footer: counts are what the Lock Screen
    /// renders in the clear; names and titles stay inside the envelope.
    static let liveActivityFooter =
        String(localized: "The Lock Screen shows aggregate status counts and update timing. Agent, Host, and task details stay encrypted.")

    /// Shown under the Live Activity toggle when the system-wide permission
    /// is off. Mirrors the Agent Notifications denied-state wording.
    static let liveActivityDisabledHint =
        String(localized: "Live Activities are turned off for Heeler. Enable them in Settings to show this Host on the Lock Screen.")
}
