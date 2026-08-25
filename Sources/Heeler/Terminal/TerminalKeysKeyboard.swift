import SwiftUI

/// The panes of the tools keyboards. Controls comes first and is selected by
/// default: it is everything Keys mode used to be, and gaining neighbours
/// should not cost the old behaviour an extra tap.
enum TerminalKeysTab: Int, CaseIterable, Identifiable {
    case controls
    // Skills before Snippets: the case order is the tab and page order.
    case skills
    case snippets
    case appearance

    var id: Self { self }

    var systemImageName: String {
        switch self {
        case .controls: "square.grid.3x3"
        // Not `curlybraces`: that says "code snippet", and these are phrases.
        case .snippets: "quote.bubble"
        case .skills: "sparkles"
        case .appearance: "paintpalette"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .controls: "Control Keys"
        case .snippets: "Snippets"
        case .skills: "Skills"
        case .appearance: "Terminal Appearance"
        }
    }
}

/// What the Skills pane needs from the screen: the store that probes and
/// caches the agent's skills. Only agents of a kind with a skills source
/// catalog get one; the tab is hidden otherwise.
@MainActor
struct TerminalSkillsContext {
    let store: SkillsPaneStore
    /// Opens the skill's full document. That is a sheet, which the keyboard
    /// cannot host, so the screen owns the presentation and the keyboard
    /// only asks — the Snippets-management arrangement.
    let viewContent: (AgentSkill) -> Void

    init(
        store: SkillsPaneStore,
        viewContent: @escaping (AgentSkill) -> Void = { _ in }
    ) {
        self.store = store
        self.viewContent = viewContent
    }
}

/// What a tools keyboard needs from the app to fill its Snippets, Skills,
/// and Appearance panes.
@MainActor
struct TerminalKeysContext {
    let settings: TerminalSettings
    /// Nil hides the Skills tab: the agent's kind has no skills mechanism
    /// this app knows how to probe.
    let skills: TerminalSkillsContext?
    /// Opens the Snippets management surface. That means leaving the keyboard,
    /// so the screen owns the presentation and the keyboard only asks.
    let manageSnippets: () -> Void

    init(
        settings: TerminalSettings,
        skills: TerminalSkillsContext? = nil,
        manageSnippets: @escaping () -> Void
    ) {
        self.settings = settings
        self.skills = skills
        self.manageSnippets = manageSnippets
    }

    var tabs: [TerminalKeysTab] {
        TerminalKeysTab.allCases.filter { tab in
            tab != .skills || skills != nil
        }
    }
}
