import Foundation

/// Shared session-selection rules for the two places a Host's herdr session
/// can change: onboarding (`HostOnboardingView`) and the Console session
/// switcher (#269). Keeping them in one place stops the two pickers from
/// drifting on what counts as selected and what may be chosen.
enum HerdrSessionSelection {
    /// `Host.sessionName` is blank for the default session, so the stored form
    /// is not always the displayed name.
    static func sessionName(for session: HerdrSession) -> String {
        session.isDefault ? "" : session.name
    }

    static func isSelected(_ session: HerdrSession, currentSessionName: String) -> Bool {
        currentSessionName == sessionName(for: session)
    }

    /// A stopped named session has no socket to reach, so selecting it would
    /// point the Host at a socket that does not exist yet. The selected
    /// session is not a choice either — it is already in effect.
    static func isSelectable(_ session: HerdrSession, currentSessionName: String) -> Bool {
        if isSelected(session, currentSessionName: currentSessionName) { return false }
        return session.isDefault || session.isRunning
    }
}
