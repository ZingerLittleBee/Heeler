import Testing

@testable import Heeler

@Suite("Agent list fields preview")
struct AgentListFieldsPreviewTests {
    @Test func sampleValuesDriveTheSharedRendererForBuiltinsAndCustomTokens() throws {
        let agent = AgentListFieldsPreview.sampleAgent(hostName: "Studio Mac")
        #expect(agent.hostName == "Studio Mac")
        #expect(agent.agent.kind == "claude")
        #expect(agent.agent.status == .idle)
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
        #expect(presentation.rows == rendered)
        #expect(presentation == AgentCardPresentation(agent: agent, layout: layout))

        let tokens = rendered.flatMap { $0.compactMap(\.token) }
        #expect(!tokens.contains(.stateIcon) && !tokens.contains(.stateText))
        #expect(tokens == [
            .workspace, .tab, .pane, .agent, .terminalTitle, .terminalTitleStripped, .custom("branch"),
        ])
        #expect(rendered.map { $0.map(\.text).joined() }
            == ["heeler · 1 · claude · claude · fix sidebar sync · fix sidebar sync · feat/sidebar"])
        let workspace = try #require(rendered.flatMap { $0 }.first { $0.token == .workspace })
        #expect(workspace.fg == color && workspace.bold == true && workspace.dim == true)
        #expect(presentation.headline == rendered.first?.map(\.text).joined())
    }

    @Test func emptyRowsUseTheConsoleAgentNameFallbackNotAnIllustrativeStatusLabel() {
        let agent = AgentListFieldsPreview.sampleAgent(hostName: "Studio Mac")
        for layout in [
            AgentRowLayout(rows: []),
            AgentRowLayout(rows: [[], [.init(.stateIcon)], [.init(.custom("absent"))]]),
        ] {
            #expect(AgentRowRenderer.render(layout: layout, agent: agent).isEmpty)
            let presentation = AgentListFieldsPreview.presentation(layout: layout, hostName: "Studio Mac")
            #expect(presentation == AgentCardPresentation(agent: agent, layout: layout))
            #expect(presentation.headline == agent.agent.displayName)
            #expect(presentation.headline == "claude")
            #expect(presentation.headline != "Status only")
            #expect(presentation.additionalRows.isEmpty)
        }
    }
}
