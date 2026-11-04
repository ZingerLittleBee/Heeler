import Foundation

/// Whether Grok Build's screen, read just before a send, shows the session
/// Chat follows. herdr follows `/new`, `/clear` and a message sent from the
/// dashboard, but keeps reporting the old session after `/resume`, `/fork`
/// and going back from the dashboard, and a message pasted then lands in a
/// conversation Chat doesn't show. Text sent from the Welcome screen that
/// `/welcome` opens starts a new session first, which herdr then reports
/// (1.0.62, live): a message runs in it, and a `/resume` leaves herdr on it,
/// empty, while the screen shows the resumed session. Three readings run in
/// order, and the first verdict wins: the Welcome screen, a Session line,
/// and the newest message on screen. Each says nothing when unsure; the
/// post-send witness catches what they miss. The dashboard's view of an
/// agent stays on whichever agent the dashboard opened last (1.0.62,
/// live), so there a send goes only when the readings find this
/// conversation.
enum GrokSessionCheck {
    static let welcomeReason =
        "Grok Build is on its welcome screen, where a message starts a new session. Go back with Resume session (Ctrl+R) in the terminal, or start the new one there."
    static let sessionLineReason =
        "Grok Build's screen shows another session. If you just ran /new or /clear, Chat follows it in a moment; send again then. Otherwise switch back to this conversation in the terminal first."
    static let unknownPromptReason =
        "Grok Build's screen shows a message this conversation doesn't have. It may be in another session, or the terminal may be scrolled up. Check the terminal, then send again."
    static let agentViewReason =
        "Grok Build is showing an agent from its dashboard, which may not be this conversation. Go back to the conversation in the terminal first."

    /// The verdict on `screen` for the session `input` names. Without one,
    /// while herdr reports no session Chat follows, only the dashboard's
    /// view of an agent holds.
    static func verdict(_ screen: ANSIScreen, _ input: ChatSessionCheckInput?) -> ChatScreenSessionVerdict {
        let grok = GrokScreen(screen)
        let verdict = input.map { readings(grok, $0) } ?? .unknown
        if grok.isDashboardOverlay, verdict != .thisSession { return .otherSession(agentViewReason) }
        return verdict
    }

    private static func readings(_ grok: GrokScreen, _ input: ChatSessionCheckInput) -> ChatScreenSessionVerdict {
        // At Grok's start the session has no prompt yet, and a message from
        // the Welcome screen is its first.
        if grok.isWelcome, hasMessages(input.transcript) { return .otherSession(welcomeReason) }
        // Grok prints the line into the scrollback of the session it names
        // (`lifecycle.rs`, `load.rs`), so the screen shows that session,
        // whatever messages follow the line.
        if let line = grok.sessionLine, line.sessionID != input.sessionID.lowercased() {
            return .otherSession(sessionLineReason)
        }
        return newestMessage(grok, input)
    }

    /// Whether the conversation has a message, read or not. A transcript
    /// restored from the device's copy records no prompts, but keeps where
    /// the newest starts and the turns they open.
    private static func hasMessages(_ transcript: ChatTranscript) -> Bool {
        !transcript.recordedPrompts.isEmpty || transcript.latestPromptOffset != nil || !transcript.turns.isEmpty
            || transcript.needsOlderHistory
    }

    /// The bottom-most user row against the transcript, once Chat's reading
    /// of it is complete: herdr reports Grok idle and its screen agrees, a
    /// poll that started since then has been applied, and the newest turn's
    /// opener is loaded, or the conversation has no message at all. A window
    /// that starts inside a long turn opens none. A session with no message
    /// has none of its own to show (`/new` shows only its Session line), so
    /// a typed one is another session's, as after a `/resume` typed on the
    /// Welcome screen, which leaves herdr on the new, empty session.
    private static func newestMessage(_ grok: GrokScreen, _ input: ChatSessionCheckInput) -> ChatScreenSessionVerdict {
        let transcript = input.transcript
        guard input.activity == .idle, grok.statusRow == nil, input.polledSinceIdle,
            !hasMessages(transcript) || opensWithReadPrompt(transcript),
            // Never an older row: the terminal may be scrolled up.
            let row = grok.userRows.last,
            // A command, shell mode, or a paste or image chip: the
            // scrollback doesn't show what the transcript records.
            let lead = row.text.first, !"/![".contains(lead)
        else { return .unknown }
        let text = key(of: row)
        guard !text.isEmpty, !input.unrecordedSendKeys.contains(where: { squeezed($0).hasPrefix(text) }) else {
            return .unknown
        }
        let prompts = transcript.recordedPrompts.map { squeezed($0.text) }
        if prompts.last?.hasPrefix(text) == true {
            // A send another session took reads the same on its screen.
            let misdirected = input.misdirectedSendKeys.contains { squeezed($0).hasPrefix(text) }
            return misdirected ? .unknown : .thisSession
        }
        return prompts.contains { $0.hasPrefix(text) } ? .unknown : .otherSession(unknownPromptReason)
    }

    /// The newest turn opens with a prompt Chat has read.
    private static func opensWithReadPrompt(_ transcript: ChatTranscript) -> Bool {
        guard let opener = transcript.turns.last?.firstEntryID else { return false }
        return transcript.recordedPrompts.contains { $0.entryID == opener }
    }

    /// What a row is compared on: its text without whitespace, which
    /// wrapping changes, and without the `…` Grok ends a cut message with.
    private static func key(of row: GrokScreen.UserRow) -> String {
        var text = row.text
        if text.hasSuffix("…") { text.removeLast() }
        return squeezed(text)
    }

    private static func squeezed(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }
}
