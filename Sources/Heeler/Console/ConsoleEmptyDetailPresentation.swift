import SwiftUI

struct ConsoleEmptyDetailPresentation: Equatable {
    enum Action: String, CaseIterable, Identifiable {
        case showAgents, newAgent, hosts

        var id: Self { self }
        var title: String {
            switch self {
            case .showAgents: "Show Agents"
            case .newAgent: "New Agent"
            case .hosts: "Hosts"
            }
        }
        var systemImage: String {
            switch self {
            case .showAgents: "sidebar.left"
            case .newAgent: "plus"
            case .hosts: "server.rack"
            }
        }
        var shortcutHint: String? {
            switch self {
            case .showAgents: nil
            case .newAgent: "⌘N"
            case .hosts: "⌘⇧H"
            }
        }
    }

    let title: String
    let systemImage: String
    let message: String
    let canStartAgent: Bool
    let actions: [Action]
    /// The Terminals tab asks for a shell instead: the same actions, worded
    /// for terminals, with `.newAgent` opening New Terminal.
    let listsTerminals: Bool

    init(hasHosts: Bool, showsAgentsAction: Bool = true, listsTerminals: Bool = false) {
        actions = showsAgentsAction ? Action.allCases : [.newAgent, .hosts]
        canStartAgent = hasHosts
        self.listsTerminals = listsTerminals
        if listsTerminals {
            title = "No Terminal Selected"
            systemImage = "terminal"
            message = hasHosts
                ? "Choose a terminal or open a new one."
                : "Add a Host to open its terminals."
        } else {
            title = "No Agent Selected"
            systemImage = "rectangle.on.rectangle"
            message = hasHosts
                ? "Choose an Agent or start a new one to view its live terminal."
                : "Add a Host to start an Agent and view its live terminal."
        }
    }

    func title(for action: Action) -> String {
        guard listsTerminals else { return action.title }
        switch action {
        case .showAgents: return "Show Terminals"
        case .newAgent: return "New Terminal"
        case .hosts: return action.title
        }
    }

    /// ⌘N stays New Agent everywhere, so it is not advertised on New Terminal.
    func shortcutHint(for action: Action) -> String? {
        listsTerminals && action == .newAgent ? nil : action.shortcutHint
    }

    func isEnabled(_ action: Action) -> Bool {
        action != .newAgent || canStartAgent
    }
}

struct ConsoleEmptyDetailView: View {
    let presentation: ConsoleEmptyDetailPresentation
    let perform: (ConsoleEmptyDetailPresentation.Action) -> Void

    var body: some View {
        ContentUnavailableView {
            Label(presentation.title, systemImage: presentation.systemImage)
        } description: {
            Text(presentation.message)
        } actions: {
            ForEach(presentation.actions) { action in
                Button {
                    perform(action)
                } label: {
                    HStack {
                        Label(presentation.title(for: action), systemImage: action.systemImage)
                        if let hint = presentation.shortcutHint(for: action) {
                            Text(hint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!presentation.isEnabled(action))
                .hoverEffect(.highlight)
            }
        }
    }
}
