import Foundation
import Testing

@testable import Heeler

@Suite("Agent row renderer")
struct AgentRowRendererTests {
    private func agent(tabLabel: String? = "1", tabPosition: Int? = 1, tabCount: Int = 1) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "Host",
            agent: Agent(AgentInfo(
                agentStatus: .working, focused: false, paneID: "opaque-pane", revision: 1,
                tabID: "opaque-tab", terminalID: "term", workspaceID: "workspace",
                agent: "claude", displayAgent: "Reviewer", name: "fallback",
                stateLabels: ["working": "busy"], terminalTitle: "◑ Fix the build",
                terminalTitleStripped: "Fix the build", title: "Manual pane",
                tokens: ["pin_icon": "📌", "markup": "**literal**", "empty": "", "spaces": " \n"])),
            workspaceLabel: "Heeler", repositoryCheckout: nil,
            tabLabel: tabLabel, tabPosition: tabPosition, workspaceTabCount: tabCount)
    }

    @Test func defaultElidesAutomaticSingleTabAndStatusFields() {
        let rows = AgentRowRenderer.render(layout: .heelerDefault, agent: agent())
        #expect(rows.map { $0.map(\.text).joined() } == ["Heeler", "Reviewer"])
        #expect(rows.map { $0.compactMap(\.token) } == [[.workspace], [.agent]])
    }

    @Test func tabVisibilityUsesWorkspaceCountAndPositionalAutomaticName() {
        let layout = AgentRowLayout(rows: [[.init(.tab)]])
        for (label, position, count, expected) in [
            ("1", 1, 1, false), ("1", 1, 2, true), ("Build", 1, 1, true),
            ("2", 1, 1, true), ("", 1, 2, false),
        ] {
            let result = AgentRowRenderer.render(layout: layout, agent: agent(tabLabel: label, tabPosition: position, tabCount: count))
            #expect(!result.isEmpty == expected)
        }
        #expect(AgentRowRenderer.render(layout: layout, agent: agent(tabLabel: nil, tabCount: 2)).isEmpty)
    }

    @Test func allTitleTokensStayDistinctAndPluginTextIsLiteral() {
        let layout = AgentRowLayout(rows: [[
            .init(.stateIcon), .init(.pane), .init(.terminalTitle), .init(.terminalTitleStripped),
            .init(.stateText), .init(.custom("pin_icon")), .init(.custom("markup")),
        ]])
        let rows = AgentRowRenderer.render(layout: layout, agent: agent())
        #expect(rows.map { $0.map(\.text).joined() }
                == ["Manual pane · ◑ Fix the build · Fix the build · 📌 · **literal**"])
    }

    @Test func omittedTokensLeaveNoSeparatorsOrEmptyRows() {
        let layout = AgentRowLayout(rows: [
            [.init(.stateIcon), .init(.custom("missing")), .init(.stateText)], [],
            [.init(.custom("empty")), .init(.custom("spaces"))],
            [.init(.custom("missing")), .init(.workspace), .init(.custom("empty")),
             .init(.agent), .init(.custom("missing"))],
        ])
        #expect(AgentRowRenderer.render(layout: layout, agent: agent()).map { $0.map(\.text).joined() }
                == ["Heeler · Reviewer"])
    }

    @Test func kindOverrideReplacesRowsAndStylesDoNotReachSeparators() throws {
        let color = try #require(HexColor("#123456"))
        let layout = AgentRowLayout(rows: [[.init(.pane)]], rowsByAgent: ["claude": [[
            .init(.workspace, fg: color, bold: false, dim: true), .init(.agent, bold: true),
        ]]])
        let row = try #require(AgentRowRenderer.render(layout: layout, agent: agent()).first)
        #expect(row.count == 3)
        #expect(row[0].fg == color && row[0].bold == false && row[0].dim == true)
        #expect(row[1] == .separator)
        #expect(row[2].bold == true && row[2].dim == nil && row[2].fg == nil)
        let emptyOverride = AgentRowLayout(rows: layout.rows, rowsByAgent: ["claude": []])
        #expect(AgentRowRenderer.render(layout: emptyOverride, agent: agent()).isEmpty)
    }

    @Test func heelerOnlyFieldsRenderHostStatusAndDirectory() {
        let withCwd = ConsoleAgent(
            hostID: UUID(), hostName: "Studio Mac",
            agent: Agent(
                terminalID: "term", kind: "claude", title: "Fix", status: .idle,
                workspaceID: "w", tabID: "t", paneID: "p", cwd: "/work/heeler", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
        let layout = AgentRowLayout(rows: [[.init(.host), .init(.status), .init(.directory)]])
        #expect(AgentRowRenderer.render(layout: layout, agent: withCwd).map { $0.map(\.text).joined() }
                == ["Studio Mac · Idle · /work/heeler"])
        #expect(AgentRowRenderer.render(layout: layout, agent: withCwd).flatMap { $0.compactMap(\.token) }
                == [.host, .status, .directory])

        let empty = ConsoleAgent(
            hostID: UUID(), hostName: "  ",
            agent: Agent(
                terminalID: "term", kind: "claude", title: "Fix", status: .working,
                workspaceID: "w", tabID: "t", paneID: "p", cwd: " \n", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
        #expect(AgentRowRenderer.render(layout: layout, agent: empty).map { $0.map(\.text).joined() }
                == ["Working"])
    }

    @Test func missingTitlesAndWorkspaceNeverRenderOpaqueIDs() {
        let row = ConsoleAgent(hostID: UUID(), hostName: "Host", agent: Agent(
            terminalID: "terminal", kind: "codex", title: "Legacy title", status: .idle,
            workspaceID: "workspace-id", tabID: "tab-id", paneID: "pane-id", cwd: "", revision: 0),
            workspaceLabel: nil, repositoryCheckout: nil)
        let layout = AgentRowLayout(rows: [[.init(.pane), .init(.workspace), .init(.tab),
                                           .init(.terminalTitle), .init(.terminalTitleStripped), .init(.agent)]])
        #expect(AgentRowRenderer.render(layout: layout, agent: row).map { $0.map(\.text).joined() } == ["codex"])
    }
}
