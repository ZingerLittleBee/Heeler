import Foundation

/// Separators are separate unstyled spans. UI consumers must display `text`
/// as plain text, including plugin values, rather than interpreting Markdown.
struct RenderedToken: Equatable, Sendable {
    let token: AgentRowToken?
    let text: String
    let fg: HexColor?
    let bold: Bool?
    let dim: Bool?

    var isSeparator: Bool { token == nil }

    static let separator = RenderedToken(token: nil, text: " · ", fg: nil, bold: nil, dim: nil)
}

enum AgentRowRenderer {
    /// `hiding` drops fields the surrounding list already shows; a row left
    /// empty gives way to the next. Where the row leads with the program's
    /// mark, `omittingMarkedKind` drops an Agent field that only spells out
    /// the kind from a row with another field: a renamed Agent keeps its
    /// name, and a row of the Agent field alone keeps it.
    static func render(
        layout: AgentRowLayout, agent: ConsoleAgent, hiding: Set<AgentRowToken> = [],
        omittingMarkedKind: Bool = false
    ) -> [[RenderedToken]] {
        let omitsKind = omittingMarkedKind && spellsOutMarkedKind(agent)
        return layout.rows(forAgentKind: agent.agent.kind).compactMap { row in
            // Judged before `hiding`: a field the card shows elsewhere still
            // keeps the kind off its row.
            let omitsAgent = omitsKind && row.contains { configured in
                configured.token != .agent
                    && value(for: configured.token, agent: agent).flatMap(nonempty) != nil
            }
            var rendered: [RenderedToken] = []
            for configured in row
            where !hiding.contains(configured.token) && !(omitsAgent && configured.token == .agent) {
                guard let text = value(for: configured.token, agent: agent),
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                if !rendered.isEmpty { rendered.append(.separator) }
                rendered.append(RenderedToken(
                    token: configured.token, text: text, fg: configured.fg,
                    bold: configured.bold, dim: configured.dim))
            }
            return rendered.isEmpty ? nil : rendered
        }
    }

    /// The Agent field reads only the kind, which the kind's mark names.
    private static func spellsOutMarkedKind(_ row: ConsoleAgent) -> Bool {
        let kind = row.agent.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentKindMark.names(kind: kind)
            && row.agent.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(kind) == .orderedSame
    }

    private static func value(for token: AgentRowToken, agent row: ConsoleAgent) -> String? {
        switch token {
        case .stateIcon, .stateText: nil // The row's status badge or ring owns both.
        case .workspace: row.workspaceLabel
        case .tab: row.showsTabLabel ? row.tabLabel : nil
        case .pane: row.agent.paneTitle ?? row.paneLabel
        case .agent: row.agent.displayName
        case .terminalTitle: row.agent.terminalTitle
        case .terminalTitleStripped: row.agent.terminalTitleStripped
        case .host: nonempty(row.hostName)
        case .status: row.agent.status.displayTitle.flatMap(nonempty)
        case .directory: nonempty(row.displayCwd)
        case .custom(let name): row.agent.tokens[name]
        }
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
