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
    /// A command the menu offers only in another state.
    case commandUnavailable(String)
    /// The Agent's input box is not in a state to take a message.
    case inputNotReady(String)

    var message: String {
        switch self {
        case .agentBlocked:
            "The Agent is waiting for an answer. Answer it first."
        case .unsafeText(let reason):
            reason
        case .unknownCommand(let name):
            "/\(name) is not in the menu. Pick a command from the menu, or open the terminal to run it."
        case .commandUnavailable(let reason):
            reason
        case .inputNotReady(let reason):
            reason
        }
    }

    /// Whether the terminal can do what Chat declined.
    var suggestsTerminal: Bool {
        switch self {
        case .agentBlocked, .commandUnavailable: false
        case .unsafeText, .unknownCommand, .inputNotReady: true
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
    /// Runs after `agent.prompt` succeeds with the text it sent; false means
    /// the text never left the Agent's input box. Nothing is resent.
    var verify: (@MainActor (String) async -> Bool)?

    static let terminal = ComposerDeliveryPolicy(
        route: .terminal, insertsIntoAttachWhenBlocked: true, outgoingText: { $0 },
        validate: { _ in nil }, preflight: nil, verify: nil)
}

/// A refusal the Composer shows until the draft it refused changes.
struct ComposerNotice: Equatable {
    let refusal: ComposerRefusal
    /// The draft as it stood after the refusal.
    let draft: String
}
