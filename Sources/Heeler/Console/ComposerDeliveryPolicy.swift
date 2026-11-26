import Foundation

/// Which surface a Composer message was sent from. Each surface shows only
/// its own failures, and a retry goes back the same way.
enum ComposerRoute: Sendable, Equatable {
    case terminal
    case chat
}

/// Why a draft was not sent. The text stays the user's to edit.
enum ComposerRefusal: Equatable, Sendable {
    /// The Agent is waiting on a dialog. Chat answers dialogs with its own
    /// cards and never types into the terminal.
    case agentBlocked
    /// The text would make the Agent do something other than read a
    /// message: run a shell command, exit, or interpret control bytes.
    case unsafeText(String)
    /// A leading `/command` the menu does not offer.
    case unknownCommand(String)
    /// A command the menu offers only while the Agent is idle.
    case commandAwaitsIdle(String)
    /// A command the menu offers, but not in the form typed.
    case commandUnavailable(String)
    /// The Agent's input box is not in a state to take a message.
    case inputNotReady(String)
    /// The screen read couldn't confirm an unobstructed input box (an overlay
    /// or unrecognized box shape). Unlike `inputNotReady`, the user may tap
    /// Send Anyway to override only this check while keeping Blocked, dialog,
    /// shell-mode, draft, and session checks in place.
    case unconfirmedInputBox(String)
    /// The program has bracketed paste off, so a paste would read as typing.
    case programNotAcceptingPaste
    /// A paste went out and its submit did not. The reason says whether the
    /// text may still be in the terminal, which no later status changes.
    case notSubmitted(String)

    var message: String {
        switch self {
        case .agentBlocked:
            String(localized: "The Agent is waiting for an answer. Answer it first.")
        case .unsafeText(let reason):
            reason
        case .unknownCommand(let name):
            String(localized: "/\(name) is not in the menu. Pick a command from the menu, or open the terminal to run it.")
        case .commandAwaitsIdle(let name):
            String(localized: "/\(name) is available once the Agent is idle.")
        case .commandUnavailable(let reason):
            reason
        case .inputNotReady(let reason), .unconfirmedInputBox(let reason):
            reason
        case .programNotAcceptingPaste:
            String(localized: "The program is not accepting a paste right now, so nothing was sent.")
        case .notSubmitted(let reason):
            reason
        }
    }

    /// Whether the terminal can do what Chat declined.
    var suggestsTerminal: Bool {
        switch self {
        case .agentBlocked, .commandAwaitsIdle, .commandUnavailable, .programNotAcceptingPaste, .notSubmitted: false
        case .unsafeText, .unknownCommand, .inputNotReady, .unconfirmedInputBox: true
        }
    }

    /// Whether this refusal described the input box of the conversation Chat
    /// followed, so switching conversations clears the notice.
    var clearsOnConversationChange: Bool {
        switch self {
        case .inputNotReady, .unconfirmedInputBox: true
        case .agentBlocked, .unsafeText, .unknownCommand, .commandAwaitsIdle, .commandUnavailable,
            .programNotAcceptingPaste, .notSubmitted:
            false
        }
    }

    /// Whether the same draft may go once Agent Status becomes `status`, so
    /// the notice ends then. A refusal about the Agent's state ends with the
    /// state it named; one about the input box with any change, since what
    /// the box shows follows the Agent. A refusal of the text itself holds
    /// until the text changes.
    func endsWhenStatusBecomes(_ status: AgentStatus) -> Bool {
        switch self {
        case .agentBlocked: ChatAgentActivity(status) != .blocked
        case .commandAwaitsIdle: ChatAgentActivity(status) == .idle
        case .inputNotReady, .unconfirmedInputBox, .programNotAcceptingPaste: true
        case .unsafeText, .unknownCommand, .commandUnavailable, .notSubmitted: false
        }
    }
}

/// How a Composer delivers a draft. The terminal's policy is the Composer's
/// original behavior; Chat's validates the text, rewrites commands for the
/// program, checks the Agent's input box first, and never touches the PTY.
struct ComposerDeliveryPolicy: Sendable {
    var route: ComposerRoute
    /// Terminal types a Blocked draft into the Attach PTY without Enter.
    var insertsIntoAttachWhenBlocked: Bool
    /// What `agent.prompt` sends for the typed text.
    var outgoingText: @MainActor (String) -> String
    /// Runs before the draft is cleared; a refusal keeps it as typed.
    var validate: @MainActor (String) -> ComposerRefusal?
    /// Runs once the echo shows and before anything is sent; a refusal
    /// returns the text to the draft.
    var preflight: (@MainActor (String) async -> ComposerRefusal?)?
    /// Alternate preflight used when the user chooses Send Anyway after an
    /// `.unconfirmedInputBox` refusal: still runs Blocked, session, dialog,
    /// shell-mode, draft, and send-concern checks, bypassing only overlay /
    /// unrecognized-box screen holds.
    var unconfirmedInputBoxPreflight: (@MainActor (String) async -> ComposerRefusal?)? = nil
    /// Runs after `agent.prompt` succeeds with the text it sent; false means
    /// the text never left the Agent's input box. Nothing is resent.
    var verify: (@MainActor (String) async -> Bool)?
    var submitChat: (@MainActor (UUID, String) async -> CheckedSendOutcome)?
    /// The Attach of the window sending, which a herdr-core Send on this route
    /// types into: one Agent's Composer can be open in several windows, each with
    /// a viewer of its own. Nothing on a Herdr TUI Host.
    var coreAttach: AgentAttachStore?
    /// Which conversation Chat follows, a number that changes whenever it
    /// follows another (`AgentChatStore.conversationGeneration`). A refusal
    /// about the input box notes it, and ends once Chat follows another.
    var conversation: (@MainActor () -> Int)?

    static let terminal = ComposerDeliveryPolicy(
        route: .terminal, insertsIntoAttachWhenBlocked: true, outgoingText: { $0 },
        validate: { _ in nil }, preflight: nil, verify: nil)

    /// Prepends a guard that runs before both the regular preflight and the
    /// Send Anyway unconfirmed-input-box preflight.
    mutating func prependingPreflight(
        _ before: @escaping @MainActor (String) async -> ComposerRefusal?
    ) {
        let regular = preflight
        preflight = { text in
            if let refusal = await before(text) { return refusal }
            return await regular?(text)
        }
        if let override = unconfirmedInputBoxPreflight {
            unconfirmedInputBoxPreflight = { text in
                if let refusal = await before(text) { return refusal }
                return await override(text)
            }
        }
    }

    /// This policy with `/name` let past the menu, for a Send Anyway the
    /// user chose after `unknownCommand(name)`. Every other refusal, the
    /// input box read and the delivery check still apply.
    func admitting(unknownCommand name: String) -> ComposerDeliveryPolicy {
        var policy = self
        let validate = self.validate
        policy.validate = { text in
            let refusal = validate(text)
            return refusal == .unknownCommand(name) ? nil : refusal
        }
        return policy
    }

    /// This policy with an `.unconfirmedInputBox` screen-recognition hold
    /// overridden, for a Send Anyway the user chose after that refusal.
    /// Validation, Blocked, session, dialog, shell-mode, draft, and
    /// send-concern checks still apply.
    func admittingUnconfirmedInputBox() -> ComposerDeliveryPolicy {
        var policy = self
        if let override = unconfirmedInputBoxPreflight {
            policy.preflight = override
        } else if let regular = preflight {
            policy.preflight = { text in
                let refusal = await regular(text)
                if case .unconfirmedInputBox = refusal { return nil }
                return refusal
            }
        }
        return policy
    }
}

/// A refusal the Composer shows until the draft it refused changes, a later
/// Send goes, or Agent Status changes in a way that ends it.
struct ComposerNotice: Equatable {
    let refusal: ComposerRefusal
    /// The surface that was refused; only it shows the notice.
    let route: ComposerRoute
    /// The conversation Chat followed when the refusal came
    /// (`ComposerDeliveryPolicy.conversation`).
    var conversation: Int?
    /// The failed message whose Retry was refused, or nil when the draft
    /// was. Send Anyway sends what was refused.
    var retried: UUID?
    /// The `/command` already admitted by a prior Send Anyway on this draft,
    /// carried forward if preflight then held with `.unconfirmedInputBox`.
    var admittedCommand: String? = nil
}
