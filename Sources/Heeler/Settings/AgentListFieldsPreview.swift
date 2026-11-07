import SwiftUI

/// Console preview for a Host's current rows.
///
/// Draws the same `AgentCardView` the Agent list uses, with sample values, so
/// typography, status, each row's right side, Changes totals, and field
/// emphasis cannot drift. The Host section owns the strip label, tint, and padding.
struct AgentListFieldsPreview: View {
    let layout: AgentRowLayout
    let hostName: String
    var followsPlugin = true
    /// The program the sample runs, whose mark decides whether the Agent
    /// field shows; see `kind(onHost:among:)`.
    var kind = Self.sampleKind

    var body: some View {
        AgentCardView(
            agent: Self.sampleAgent(hostName: hostName, layout: layout, followsPlugin: followsPlugin, kind: kind),
            layout: layout,
            sampleChanges: Self.sampleChanges)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityRespondsToUserInteraction(false)
    }

    /// Same presentation the Console card uses for this sample.
    static func presentation(
        layout: AgentRowLayout, hostName: String, kind: String = sampleKind
    ) -> AgentCardPresentation {
        AgentCardPresentation(
            agent: sampleAgent(hostName: hostName, layout: layout, kind: kind), layout: layout,
            leadsWithMark: true)
    }

    nonisolated static let sampleKind = "claude"

    /// The program the Host runs most, so a Host of programs without a logo
    /// previews the Agent field its list keeps; Claude where it runs none.
    nonisolated static func kind(onHost hostID: UUID, among agents: [ConsoleAgent]) -> String {
        let kinds = agents.filter { $0.hostID == hostID }
            .map { $0.agent.kind.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let counts = Dictionary(kinds.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? sampleKind
    }

    /// Deterministic sample values for built-in and custom tokens, and each
    /// label `layout` names on either side, shown by its key; not a live
    /// Agent. Done, so the ring and any status field show a settled status.
    static func sampleAgent(
        hostName: String, layout: AgentRowLayout? = nil, followsPlugin: Bool = true, kind: String = sampleKind
    ) -> ConsoleAgent {
        let title = followsPlugin ? String(localized: "fix sidebar sync") : String(localized: "fix login redirect")
        var tokens = ["branch": "feat/sidebar"]
        for case .label(let key) in ((layout?.rows ?? []) + (layout?.trailing ?? [])).joined().map(\.token) {
            tokens[key] = key
        }
        return ConsoleAgent(
            hostID: sampleHostID,
            hostName: hostName,
            agent: Agent(
                terminalID: "preview-terminal",
                kind: kind,
                title: title,
                status: .done,
                workspaceID: "preview-workspace",
                tabID: "preview-tab",
                paneID: "preview-pane",
                cwd: "/work/heeler",
                revision: 1,
                name: kind,
                terminalTitle: title,
                terminalTitleStripped: title,
                paneTitle: kind,
                tokens: tokens),
            workspaceLabel: "heeler",
            repositoryCheckout: nil,
            tabLabel: "1",
            tabPosition: 1,
            workspaceTabCount: 2)
    }

    /// Where the list shows a Checkout's line totals, with sample counts.
    static let sampleChanges = ChangesBadge(
        totals: ChangesTotals(trackedFiles: 3, added: 12, removed: 7))

    private static let sampleHostID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    ))
}
