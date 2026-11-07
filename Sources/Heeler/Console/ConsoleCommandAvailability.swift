import Foundation

enum ConsoleCommandAction: Hashable, Sendable {
    /// One-based position in the visible sidebar rows.
    case selectAgent(Int)
    case previousAgent, nextAgent, focusSearch, newAgent, settings, hosts
    case toggleInputMode, sendDraft, closeAgent
}

struct ConsoleCommandShortcut: Identifiable, Equatable, Sendable {
    let action: ConsoleCommandAction
    let title: String
    let key: Character
    var requiresShift = false

    var id: ConsoleCommandAction { action }

    /// Every entry implicitly requires Command. Terminal zoom belongs to Ghostty's adapter.
    static let all: [Self] =
        (1...9).map {
            Self(action: .selectAgent($0), title: "Select Agent \($0)", key: Character(String($0)))
        } + [
            Self(action: .previousAgent, title: String(localized: "Previous Agent"), key: "["),
            Self(action: .nextAgent, title: String(localized: "Next Agent"), key: "]"),
            Self(action: .focusSearch, title: String(localized: "Search Agents"), key: "f"),
            Self(action: .newAgent, title: String(localized: "New Agent"), key: "n"),
            Self(action: .settings, title: String(localized: "Settings…"), key: ","),
            Self(action: .hosts, title: String(localized: "Hosts"), key: "h", requiresShift: true),
            Self(action: .toggleInputMode, title: "Toggle Direct Input / Composer", key: "e"),
            Self(action: .sendDraft, title: String(localized: "Send Composer Draft"), key: "\r"),
            Self(action: .closeAgent, title: String(localized: "Close Agent View"), key: "w"),
        ]
}

/// Titles that follow the Console tab on screen. The Terminals tab searches
/// and creates terminals, and a shell's detail closes a terminal view.
struct ConsoleCommandTitles: Equatable, Sendable {
    var listsTerminals = false
    var showsShell = false

    func title(for shortcut: ConsoleCommandShortcut) -> String {
        switch shortcut.action {
        case .focusSearch where listsTerminals: String(localized: "Search Terminals")
        case .newAgent where listsTerminals: String(localized: "New Terminal")
        case .closeAgent where showsShell: String(localized: "Close Terminal View")
        default: shortcut.title
        }
    }
}

enum ConsoleCommandFocus: CaseIterable, Sendable {
    case terminal, composer, sidebar, none
}

/// Policy only. Registration and scene ownership are checked separately by the target.
struct ConsoleCommandAvailability {
    let focus: ConsoleCommandFocus
    let hasSelection: Bool
    let agentCount: Int
    let inputMode: AgentInputMode
    let hasDraft: Bool
    var offersNewItem = true

    func allows(_ action: ConsoleCommandAction) -> Bool {
        switch action {
        case .selectAgent(let position):
            (1...9).contains(position) && position <= agentCount
        case .previousAgent, .nextAgent:
            agentCount > 0
        case .toggleInputMode, .closeAgent:
            hasSelection
        case .sendDraft:
            hasSelection && focus == .composer && inputMode == .composer && hasDraft
        case .newAgent:
            offersNewItem
        case .focusSearch, .settings, .hosts:
            true
        }
    }
}

enum ConsoleCommandNavigation {
    /// Previous/next wrap. With no visible selection they start at the last/first row.
    static func destination<ID: Equatable>(
        for action: ConsoleCommandAction, in agents: [ID], selection: ID?
    ) -> ID? {
        guard !agents.isEmpty else { return nil }
        switch action {
        case .selectAgent(let position):
            guard (1...9).contains(position), position <= agents.count else { return nil }
            return agents[position - 1]
        case .previousAgent, .nextAgent:
            guard let selection, let index = agents.firstIndex(of: selection) else {
                return action == .previousAgent ? agents.last : agents.first
            }
            let step = action == .previousAgent ? -1 : 1
            return agents[(index + step + agents.count) % agents.count]
        default:
            return nil
        }
    }
}
