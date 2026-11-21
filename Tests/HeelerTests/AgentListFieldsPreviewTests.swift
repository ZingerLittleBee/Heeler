import Testing
import Foundation

@testable import Heeler

@Suite("Agent list fields preview")
struct AgentListFieldsPreviewTests {
    @MainActor
    @Test func sampleValuesDriveTheSharedRendererForBuiltinsAndCustomTokens() throws {
        let agent = AgentListFieldsPreview.sampleAgent(hostName: "Studio Mac")
        #expect(agent.hostName == "Studio Mac")
        #expect(agent.agent.kind == "claude")
        #expect(agent.agent.status == .done)
        #expect(agent.workspaceLabel == "heeler")
        #expect(agent.agent.displayName == "claude")
        #expect(agent.agent.terminalTitle == "fix sidebar sync")
        #expect(agent.agent.terminalTitleStripped == "fix sidebar sync")
        #expect(agent.agent.paneTitle == "claude")
        #expect(agent.tabLabel == "1")
        #expect(agent.showsTabLabel)
        #expect(agent.agent.tokens["branch"] == "feat/sidebar")

        let color = try #require(HexColor("#abc"))
        let layout = AgentRowLayout(rows: [[
            .init(.stateIcon), .init(.stateText),
            .init(.workspace, fg: color, bold: true, dim: true),
            .init(.tab), .init(.pane), .init(.agent),
            .init(.terminalTitle), .init(.terminalTitleStripped),
            .init(.custom("branch")),
        ]])
        let rendered = AgentRowRenderer.render(layout: layout, agent: agent)
        let presentation = AgentListFieldsPreview.presentation(layout: layout, hostName: "Studio Mac")
        #expect(presentation.rows == AgentRowRenderer.render(layout: layout, agent: agent, omittingMarkedKind: true))
        #expect(presentation == AgentCardPresentation(agent: agent, layout: layout, leadsWithMark: true))

        let tokens = rendered.flatMap { $0.compactMap(\.token) }
        #expect(!tokens.contains(.stateIcon) && !tokens.contains(.stateText))
        #expect(tokens == [
            .workspace, .tab, .pane, .agent, .terminalTitle, .terminalTitleStripped, .custom("branch"),
        ])
        #expect(rendered.map { $0.map(\.text).joined() }
            == ["heeler · 1 · claude · claude · fix sidebar sync · fix sidebar sync · feat/sidebar"])
        let workspace = try #require(rendered.flatMap { $0 }.first { $0.token == .workspace })
        #expect(workspace.fg == color && workspace.bold == true && workspace.dim == true)
        // The preview's card leads with Claude's mark, so the field that
        // only repeats the kind leaves the row.
        #expect(presentation.rows.flatMap { $0.compactMap(\.token) } == tokens.filter { $0 != .agent })
        #expect(presentation.headline == "heeler · 1 · claude · fix sidebar sync · fix sidebar sync · feat/sidebar")
    }

    /// The sample runs the Host's most common program, so a Host of programs
    /// without a logo previews the Agent field its list keeps.
    @Test func previewSamplesTheProgramTheHostRunsMost() {
        let host = UUID(), other = UUID()
        func agent(_ kind: String, on hostID: UUID) -> ConsoleAgent {
            ConsoleAgent(
                hostID: hostID, hostName: "devbox",
                agent: Agent(
                    terminalID: "t-\(kind)", kind: kind, title: "", status: .idle,
                    workspaceID: "w", tabID: "w:t", paneID: "p-\(kind)-\(UUID())", cwd: "/work", revision: 1),
                workspaceLabel: "proj", repositoryCheckout: nil)
        }
        let agents = [
            agent("claude", on: host), agent("maki", on: host), agent(" maki ", on: host),
            agent("droid", on: other), agent("droid", on: other), agent("droid", on: other),
        ]
        #expect(AgentListFieldsPreview.kind(onHost: host, among: agents) == "maki")
        #expect(AgentListFieldsPreview.kind(onHost: UUID(), among: agents) == "claude")
        // A tie goes to the earlier name, so the preview holds still.
        #expect(AgentListFieldsPreview.kind(onHost: host, among: Array(agents.prefix(2))) == "claude")

        let layout = AgentRowLayout(rows: [[.init(.workspace), .init(.agent)]])
        #expect(AgentListFieldsPreview.presentation(layout: layout, hostName: "devbox", kind: "maki").headline
            == "heeler · maki")
        #expect(AgentListFieldsPreview.presentation(layout: layout, hostName: "devbox").headline == "heeler")
    }

    @MainActor
    @Test func emptyRowsUseTheConsoleAgentNameFallbackNotAnIllustrativeStatusLabel() {
        let agent = AgentListFieldsPreview.sampleAgent(hostName: "Studio Mac")
        for layout in [
            AgentRowLayout(rows: []),
            AgentRowLayout(rows: [[], [.init(.stateIcon)], [.init(.custom("absent"))]]),
        ] {
            #expect(AgentRowRenderer.render(layout: layout, agent: agent).isEmpty)
            let presentation = AgentListFieldsPreview.presentation(layout: layout, hostName: "Studio Mac")
            #expect(presentation == AgentCardPresentation(agent: agent, layout: layout, leadsWithMark: true))
            #expect(presentation.headline == agent.agent.displayName)
            #expect(presentation.headline == "claude")
            #expect(presentation.headline != "Status only")
            #expect(presentation.additionalRows.isEmpty)
        }
    }
}
