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
    /// the kind from a row with another field on either side: a renamed
    /// Agent keeps its name, and a row of the Agent field alone keeps it.
    static func render(
        layout: AgentRowLayout, agent: ConsoleAgent, hiding: Set<AgentRowToken> = [],
        omittingMarkedKind: Bool = false
    ) -> [[RenderedToken]] {
        renderSlots(
            layout: layout, agent: agent, hiding: hiding, omittingMarkedKind: omittingMarkedKind
        ).map(\.tokens)
    }

    /// `render`, with the index of the row each rendered row came from.
    static func renderSlots(
        layout: AgentRowLayout, agent: ConsoleAgent, hiding: Set<AgentRowToken> = [],
        omittingMarkedKind: Bool = false
    ) -> [(slot: Int, tokens: [RenderedToken])] {
        let omitting = slotsOmittingAgent(layout: layout, agent: agent, omittingMarkedKind: omittingMarkedKind)
        return layout.rows(forAgentKind: agent.agent.kind).enumerated().compactMap { slot, row in
            var rendered: [RenderedToken] = []
            for configured in row {
                guard let field = field(configured, agent: agent, hiding: hiding, omittingAgent: omitting.contains(slot))
                else { continue }
                if !rendered.isEmpty { rendered.append(.separator) }
                rendered.append(field)
            }
            return rendered.isEmpty ? nil : (slot, rendered)
        }
    }

    /// Each Console row slot's right side, or nil where the layout leaves
    /// it to the list. Text fields render as `render` renders them, one run
    /// between the Host and the totals; the Host and the Checkout's Changes
    /// totals stay entries the card draws and shows as its list does, so
    /// `hiding` leaves them to it.
    static func renderTrailing(
        layout: AgentRowLayout, agent: ConsoleAgent, hiding: Set<AgentRowToken> = [],
        omittingMarkedKind: Bool = false
    ) -> [[AgentCardTrailing]]? {
        guard let sides = layout.trailing else { return nil }
        let omitting = slotsOmittingAgent(layout: layout, agent: agent, omittingMarkedKind: omittingMarkedKind)
        let slots = AgentRowSlot.slotRows(Array(sides.prefix(AgentRowLayout.maximumConsoleRows)))
        return slots.enumerated().map { slot, row in
            var entries: [AgentCardTrailing] = []
            var fields: [RenderedToken] = []
            for configured in row {
                switch configured.token {
                case .host, .changes:
                    if !fields.isEmpty { entries.append(.fields(fields)) }
                    fields = []
                    entries.append(configured.token == .host ? .host : .changes)
                default:
                    guard let field = field(
                        configured, agent: agent, hiding: hiding, omittingAgent: omitting.contains(slot))
                    else { continue }
                    if !fields.isEmpty { fields.append(.separator) }
                    fields.append(field)
                }
            }
            if !fields.isEmpty { entries.append(.fields(fields)) }
            return entries
        }
    }

    private static func field(
        _ configured: AgentRowStyledToken, agent: ConsoleAgent, hiding: Set<AgentRowToken>, omittingAgent: Bool
    ) -> RenderedToken? {
        guard !hiding.contains(configured.token), !(omittingAgent && configured.token == .agent),
            let text = value(for: configured.token, agent: agent),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return RenderedToken(
            token: configured.token, text: text, fg: configured.fg, bold: configured.bold, dim: configured.dim)
    }

    /// The row slots whose Agent field gives way to the mark: those with
    /// another field on either side. The Host and the totals on the right
    /// do not count, as the list's own Host and totals never did. Judged
    /// before `hiding`: a field the card shows elsewhere still keeps the
    /// kind off its row.
    private static func slotsOmittingAgent(
        layout: AgentRowLayout, agent: ConsoleAgent, omittingMarkedKind: Bool
    ) -> Set<Int> {
        guard omittingMarkedKind, spellsOutMarkedKind(agent) else { return [] }
        let rows = layout.rows(forAgentKind: agent.agent.kind)
        let sides = layout.trailing ?? []
        return Set((0..<max(rows.count, sides.count)).filter { slot in
            let right = sides.indices.contains(slot) ? sides[slot] : []
            let fields = (rows.indices.contains(slot) ? rows[slot] : [])
                + right.filter { $0.token != .host && $0.token != .changes }
            return fields.contains { configured in
                configured.token != .agent
                    && value(for: configured.token, agent: agent).flatMap(nonempty) != nil
            }
        })
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
        case .changes: nil // Counts the card draws, never text.
        case .custom(let name): row.agent.tokens[name]
        }
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
