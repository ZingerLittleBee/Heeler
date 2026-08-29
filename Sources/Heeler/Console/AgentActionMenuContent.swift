import SwiftUI

/// Shared Agent action-menu items for Composer and Direct Input. Ordering and
/// sectioning stay identical across both surfaces; Direct Input only adds a
/// restore-Composer hop for draft-owned actions.
enum AgentActionMenuItem: Equatable, Hashable, Sendable, CaseIterable {
    case addImage
    case addFile
    case openTerminal
    case newAgent
    case skills
    case snippets
    case worktreeDetails
    case renameAgent
    case renameWorkspace
    case closeAgent

    var title: String {
        switch self {
        case .addImage: "Add Image"
        case .addFile: "Add File"
        case .openTerminal: "Open Terminal"
        case .newAgent: "New Agent"
        case .skills: "Skills"
        case .snippets: "Snippets"
        case .worktreeDetails: "Worktree Details"
        case .renameAgent: "Rename Agent"
        case .renameWorkspace: "Rename Workspace"
        case .closeAgent: "Close Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .addImage: "photo"
        case .addFile: "doc"
        case .openTerminal: "apple.terminal"
        case .newAgent: "plus"
        case .skills: "sparkles"
        case .snippets: "quote.bubble"
        case .worktreeDetails: "arrow.triangle.branch"
        case .renameAgent: "pencil"
        case .renameWorkspace: "pencil.line"
        case .closeAgent: "trash"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .closeAgent: .destructive
        default: nil
        }
    }

    /// Draft-owned: Skills, Snippets, and Add touch the Composer draft, so
    /// Direct Input restores Composer before running them (ADR 0016).
    var isDraftOwned: Bool {
        switch self {
        case .addImage, .addFile, .skills, .snippets:
            true
        case .openTerminal, .newAgent, .worktreeDetails, .renameAgent,
            .renameWorkspace, .closeAgent:
            false
        }
    }
}

enum AgentActionMenuSection: Equatable, Hashable, Sendable, CaseIterable {
    /// Attachments for the draft.
    case addAttachments
    /// Session tools — Skills before Snippets matches the Keys keyboard tab order.
    case sessionTools
    /// Rename / close / worktree lifecycle.
    case agentLifecycle

    var items: [AgentActionMenuItem] {
        switch self {
        case .addAttachments:
            [.addImage, .addFile]
        case .sessionTools:
            [.openTerminal, .newAgent, .skills, .snippets]
        case .agentLifecycle:
            [.worktreeDetails, .renameAgent, .renameWorkspace, .closeAgent]
        }
    }
}

/// Availability and visibility rules shared by Composer Add/More and Direct
/// Input's combined More menu.
enum AgentActionMenuPolicy {
    static let composerAddSections: [AgentActionMenuSection] = [.addAttachments]
    static let composerMoreSections: [AgentActionMenuSection] = [
        .sessionTools, .agentLifecycle,
    ]
    static let directInputMoreSections: [AgentActionMenuSection] = [
        .addAttachments, .sessionTools, .agentLifecycle,
    ]

    /// Optional entries hide entirely when their action is absent.
    static func isVisible(
        _ item: AgentActionMenuItem,
        actions: AgentComposerActions
    ) -> Bool {
        switch item {
        case .skills:
            actions.showSkills != nil
        case .worktreeDetails:
            actions.showWorktreeDetails != nil
        default:
            true
        }
    }

    static func isEnabled(
        _ item: AgentActionMenuItem,
        actions: AgentComposerActions
    ) -> Bool {
        switch item {
        case .addImage, .addFile:
            actions.canBegin
        case .openTerminal:
            actions.openTerminal != nil && !actions.isOpeningTerminal
        default:
            true
        }
    }

    static func perform(
        _ item: AgentActionMenuItem,
        actions: AgentComposerActions
    ) {
        switch item {
        case .addImage:
            actions.addImage()
        case .addFile:
            actions.addFile()
        case .openTerminal:
            actions.openTerminal?()
        case .newAgent:
            actions.startAgent()
        case .skills:
            actions.showSkills?()
        case .snippets:
            actions.manageSnippets()
        case .worktreeDetails:
            actions.showWorktreeDetails?()
        case .renameAgent:
            actions.renameAgent()
        case .renameWorkspace:
            actions.renameWorkspace()
        case .closeAgent:
            actions.closeAgent()
        }
    }
}

/// One menu body for Composer Add, Composer More, and Direct Input More.
struct AgentActionMenuContent: View {
    let actions: AgentComposerActions
    let sections: [AgentActionMenuSection]
    /// When set, draft-owned items restore Composer before running (Direct Input).
    var restoreComposerThen: ((@escaping () -> Void) -> Void)? = nil

    var body: some View {
        ForEach(sections, id: \.self) { section in
            let visible = section.items.filter {
                AgentActionMenuPolicy.isVisible($0, actions: actions)
            }
            if !visible.isEmpty {
                Section {
                    ForEach(visible, id: \.self) { item in
                        button(for: item)
                    }
                }
            }
        }
    }

    private func button(for item: AgentActionMenuItem) -> some View {
        Button(item.title, systemImage: item.systemImage, role: item.role) {
            run(item)
        }
        .disabled(!AgentActionMenuPolicy.isEnabled(item, actions: actions))
    }

    private func run(_ item: AgentActionMenuItem) {
        let action = { AgentActionMenuPolicy.perform(item, actions: actions) }
        if item.isDraftOwned, let restoreComposerThen {
            restoreComposerThen(action)
        } else {
            action()
        }
    }
}
