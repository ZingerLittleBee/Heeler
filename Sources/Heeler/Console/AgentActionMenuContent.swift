import SwiftUI
import UIKit

/// Shared Agent action-menu items for Composer and Direct Input. Ordering and
/// sectioning stay identical across both surfaces; Direct Input only adds a
/// restore-Composer hop for draft-owned actions.
enum AgentActionMenuItem: Equatable, Hashable, Sendable, CaseIterable {
    case backToConsole
    case addImage
    case addFile
    case showChat
    case showAgentTerminal
    case openTerminal
    case changes
    case newAgent
    case skills
    case snippets
    case worktreeDetails
    case renameAgent
    case renameWorkspace
    case closeAgent

    var title: String {
        switch self {
        case .backToConsole: "Back to Console"
        case .addImage: "Add Image"
        case .addFile: "Add File"
        case .showChat: AgentDetailSurface.chat.showTitle
        case .showAgentTerminal: AgentDetailSurface.terminal.showTitle
        case .openTerminal: "Open Terminal"
        case .changes: "Changes"
        case .newAgent: "New Agent"
        case .skills: "Skills"
        case .snippets: "Snippets"
        case .worktreeDetails: "Worktree Details"
        case .renameAgent: "Rename Agent"
        case .renameWorkspace: "Rename Workspace"
        case .closeAgent: "Close Agent"
        }
    }

    var glyph: AgentGlyph {
        switch self {
        case .backToConsole: .symbol("chevron.left")
        case .addImage: .symbol("photo")
        case .addFile: .symbol("doc")
        case .showChat: AgentDetailSurface.chat.showGlyph
        case .showAgentTerminal: AgentDetailSurface.terminal.showGlyph
        case .openTerminal: .symbol("macwindow.badge.plus")
        case .changes: .symbol("plus.forwardslash.minus")
        case .newAgent: .symbol("plus")
        case .skills: .symbol("sparkles")
        case .snippets: .symbol("quote.bubble")
        case .worktreeDetails: .symbol("arrow.triangle.branch")
        case .renameAgent: .symbol("pencil")
        case .renameWorkspace: .symbol("pencil.line")
        case .closeAgent: .symbol("trash")
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
        case .backToConsole, .showChat, .showAgentTerminal, .openTerminal, .changes, .newAgent,
            .worktreeDetails, .renameAgent, .renameWorkspace, .closeAgent:
            false
        }
    }
}

enum AgentActionMenuSection: Equatable, Hashable, Sendable, CaseIterable {
    /// Leaving the Agent, which the edge swipe also does; spelled out so the
    /// way back is discoverable without knowing the gesture.
    case navigation
    /// Attachments for the draft.
    case addAttachments
    /// Session tools: the Chat/terminal switch first, then the rest; Skills
    /// before Snippets matches the Keys keyboard tab order.
    case sessionTools
    /// Rename / close / worktree lifecycle.
    case agentLifecycle

    var items: [AgentActionMenuItem] {
        switch self {
        case .navigation:
            [.backToConsole]
        case .addAttachments:
            [.addImage, .addFile]
        case .sessionTools:
            [.showChat, .showAgentTerminal, .openTerminal, .changes, .newAgent, .skills, .snippets]
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
        .navigation, .sessionTools, .agentLifecycle,
    ]
    static let directInputMoreSections: [AgentActionMenuSection] = [
        .navigation, .addAttachments, .sessionTools, .agentLifecycle,
    ]

    /// Optional entries hide entirely when their action is absent.
    static func isVisible(
        _ item: AgentActionMenuItem,
        actions: AgentComposerActions
    ) -> Bool {
        switch item {
        case .showChat:
            actions.showChat != nil
        case .showAgentTerminal:
            actions.showAgentTerminal != nil
        case .changes:
            actions.showChanges != nil
        case .skills:
            actions.showSkills != nil
        case .worktreeDetails:
            actions.showWorktreeDetails != nil
        case .renameAgent:
            actions.renameAgent != nil
        case .renameWorkspace:
            actions.renameWorkspace != nil
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
        case .backToConsole:
            actions.backToConsole()
        case .addImage:
            actions.addImage()
        case .addFile:
            actions.addFile()
        case .showChat:
            actions.showChat?()
        case .showAgentTerminal:
            actions.showAgentTerminal?()
        case .openTerminal:
            actions.openTerminal?()
        case .changes:
            actions.showChanges?()
        case .newAgent:
            actions.startAgent()
        case .skills:
            actions.showSkills?()
        case .snippets:
            actions.manageSnippets()
        case .worktreeDetails:
            actions.showWorktreeDetails?()
        case .renameAgent:
            actions.renameAgent?()
        case .renameWorkspace:
            actions.renameWorkspace?()
        case .closeAgent:
            actions.closeAgent()
        }
    }

    /// Production dispatch for menu taps. Direct Input supplies
    /// `restoreComposerThen` so draft-owned actions restore Composer first.
    static func dispatch(
        _ item: AgentActionMenuItem,
        actions: AgentComposerActions,
        restoreComposerThen: ((@escaping () -> Void) -> Void)? = nil
    ) {
        let action = { perform(item, actions: actions) }
        if item.isDraftOwned, let restoreComposerThen {
            restoreComposerThen(action)
        } else {
            action()
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
        ForEach(sections, id: \.self) { @Sendable section in
            MainActorContent {
                let visible = section.items.filter {
                    AgentActionMenuPolicy.isVisible($0, actions: actions)
                }
                if !visible.isEmpty {
                    Section {
                        ForEach(visible, id: \.self) { @Sendable item in
                            MainActorContent { button(for: item) }
                        }
                    }
                }
            }
        }
    }

    private func button(for item: AgentActionMenuItem) -> some View {
        Button(role: item.role) {
            AgentActionMenuPolicy.dispatch(
                item,
                actions: actions,
                restoreComposerThen: restoreComposerThen)
        } label: {
            Label(item.title, glyph: item.glyph)
        }
        .disabled(!AgentActionMenuPolicy.isEnabled(item, actions: actions))
    }
}

extension Label where Title == Text, Icon == Image {
    @MainActor
    init(_ title: String, glyph: AgentGlyph) {
        switch glyph {
        case .symbol(let name):
            self.init(title, systemImage: name)
        case .codeBubble:
            self.init {
                Text(title)
            } icon: {
                Image(uiImage: CodeBubbleGlyph.image(pointSize: 17))
            }
        }
    }
}

/// The `<>` that replaces `text.bubble`'s lines, laid over `bubble` (the
/// same outline without them) in the bubble image's own frame, so it
/// scales with whatever size the symbol is drawn at.
struct CodeBubbleMarks: Shape {
    func path(in rect: CGRect) -> Path {
        // Measured on `text.bubble` at 17 pt (a 23 x 21 canvas): its
        // lines centre at (11.44, 8.75) and are 1.15 thick.
        let unit = rect.width / 23
        let center = CGPoint(x: rect.minX + 11.44 * unit, y: rect.minY + 8.75 * unit)
        let halfHeight = 2.9 * unit, arm = 2.9 * unit, gap = 1.4 * unit
        var marks = Path()
        for side: CGFloat in [-1, 1] {
            marks.move(to: CGPoint(x: center.x + side * gap, y: center.y - halfHeight))
            marks.addLine(to: CGPoint(x: center.x + side * (gap + arm), y: center.y))
            marks.addLine(to: CGPoint(x: center.x + side * gap, y: center.y + halfHeight))
        }
        return marks.strokedPath(
            StrokeStyle(lineWidth: 1.15 * unit, lineCap: .round, lineJoin: .round))
    }
}

/// `bubble` with `CodeBubbleMarks`, flattened for menus, which take only an
/// image.
@MainActor
enum CodeBubbleGlyph {
    private static var cache: [CGFloat: UIImage] = [:]

    static func image(pointSize: CGFloat) -> UIImage {
        if let image = cache[pointSize] { return image }
        let configuration = UIImage.SymbolConfiguration(
            pointSize: pointSize, weight: .regular, scale: .medium)
        guard
            let bubble = UIImage(systemName: "bubble", withConfiguration: configuration)?
                .withTintColor(.black, renderingMode: .alwaysOriginal)
        else { return UIImage() }
        let size = bubble.size
        let drawn = UIGraphicsImageRenderer(size: size).image { _ in
            bubble.draw(at: .zero)
            UIColor.black.setFill()
            UIBezierPath(cgPath: CodeBubbleMarks().path(in: CGRect(origin: .zero, size: size)).cgPath)
                .fill()
        }
        let image = drawn.withRenderingMode(.alwaysTemplate)
        cache[pointSize] = image
        return image
    }
}
