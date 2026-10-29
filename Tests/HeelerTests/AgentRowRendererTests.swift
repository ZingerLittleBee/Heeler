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

    /// An Agent that herdr names only by its kind unless `name` renames it.
    private func kindAgent(_ kind: String, name: String? = nil) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "Host",
            agent: Agent(AgentInfo(
                agentStatus: .idle, focused: false, paneID: "opaque-pane", revision: 1,
                tabID: "opaque-tab", terminalID: "term", workspaceID: "workspace",
                agent: kind, displayAgent: name)),
            workspaceLabel: "Heeler", repositoryCheckout: nil)
    }

    /// Beside the program's mark, an Agent field that only spells out the
    /// kind leaves a row with another field, even one the card shows itself.
    /// A row of the field alone keeps it, as does a renamed Agent or a kind
    /// without a mark.
    @Test func aMarkedKindWordLeavesRowsWithOtherFields() {
        let layout = AgentRowLayout(rows: [[.init(.workspace), .init(.agent)], [.init(.agent)]])
        func texts(
            _ agent: ConsoleAgent, hiding: Set<AgentRowToken> = [], omitting: Bool = true
        ) -> [String] {
            AgentRowRenderer.render(layout: layout, agent: agent, hiding: hiding, omittingMarkedKind: omitting)
                .map { $0.map(\.text).joined() }
        }
        #expect(texts(kindAgent("claude")) == ["Heeler", "claude"])
        #expect(texts(kindAgent("Codex")) == ["Heeler", "Codex"])
        #expect(texts(kindAgent("claude", name: "reviewer")) == ["Heeler · reviewer", "reviewer"])
        #expect(texts(kindAgent("droid")) == ["Heeler · droid", "droid"])
        #expect(texts(kindAgent("claude"), omitting: false) == ["Heeler · claude", "claude"])
        #expect(texts(kindAgent("claude"), hiding: [.workspace]) == ["claude"])
    }

    /// A row's right side counts as part of it: the kind word leaves either
    /// side of a slot with another field, but the Host and the totals the
    /// card draws on the right do not count.
    @Test func aMarkedKindWordLeavesASlotWithAFieldOnEitherSide() throws {
        let layout = AgentRowLayout(
            rows: [[.init(.workspace)], [.init(.agent)], [.init(.agent)]],
            trailing: [[.init(.agent), .init(.host)], [.init(.workspace)], [.init(.host), .init(.changes)]])
        let agent = kindAgent("claude")
        #expect(AgentRowRenderer.render(layout: layout, agent: agent, omittingMarkedKind: true)
            .map { $0.map(\.text).joined() } == ["Heeler", "claude"])
        let trailing = try #require(
            AgentRowRenderer.renderTrailing(layout: layout, agent: agent, omittingMarkedKind: true))
        #expect(trailing[0] == [.host])
        #expect(trailing[1] == [.fields([RenderedToken(token: .workspace, text: "Heeler", fg: nil, bold: nil, dim: nil)])])
        #expect(trailing[2] == [.host, .changes])
        let kept = try #require(AgentRowRenderer.renderTrailing(layout: layout, agent: agent))
        #expect(kept[0] == [.fields([RenderedToken(token: .agent, text: "claude", fg: nil, bold: nil, dim: nil)]), .host])
        #expect(AgentRowRenderer.renderTrailing(layout: AgentRowLayout(rows: layout.rows), agent: agent) == nil)
    }

    /// A CLI Agent whose launch directory and SSH account are the only things
    /// a directory row depends on.
    private func directoryAgent(cwd: String, hostUsername: String?) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "Host",
            agent: Agent(AgentInfo(
                agentStatus: .working, focused: false, paneID: "opaque-pane", revision: 1,
                tabID: "opaque-tab", terminalID: "term", workspaceID: "workspace",
                agent: "claude", cwd: cwd)),
            workspaceLabel: "Heeler", repositoryCheckout: nil, hostUsername: hostUsername)
    }

    @Test func directoryShortensOnlyTheAccountsStandardHome() {
        let layout = AgentRowLayout(rows: [[.init(.directory)]])
        for (cwd, username, expected) in [
            ("/Users/aliefe/Code/bitbucket/opinnate-python", "aliefe",
             "~/Code/bitbucket/opinnate-python"),
            ("/home/dev/app", "dev", "~/app"),
            ("/root/work", "root", "~/work"),
            ("/Users/aliefe", "aliefe", "~"),
            ("/Users/aliefesh/Code", "aliefe", "/Users/aliefesh/Code"),
            ("/Users/someone/Code", "aliefe", "/Users/someone/Code"),
            ("/private/tmp", "aliefe", "/private/tmp"),
            ("/private/tmp", nil, "/private/tmp"),
        ] as [(String, String?, String)] {
            let rows = AgentRowRenderer.render(
                layout: layout, agent: directoryAgent(cwd: cwd, hostUsername: username))
            #expect(
                rows.map { $0.map(\.text).joined() } == [expected],
                "\(cwd) for user \(username ?? "none")")
        }
    }

    @Test func directoryStaysAbsentWhenTheLaunchPathIsBlank() {
        let layout = AgentRowLayout(rows: [[.init(.directory)]])
        #expect(
            AgentRowRenderer.render(
                layout: layout, agent: directoryAgent(cwd: "", hostUsername: "aliefe")
            ).isEmpty)
        #expect(
            AgentRowRenderer.render(
                layout: layout, agent: directoryAgent(cwd: " \n", hostUsername: "aliefe")
            ).isEmpty)
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

    @Test func anUnknownStatusIsLeftOutOfTheRow() {
        let unknown = ConsoleAgent(
            hostID: UUID(), hostName: "Studio Mac",
            agent: Agent(
                terminalID: "term", kind: "claude", title: "Fix", status: .unknown,
                workspaceID: "w", tabID: "t", paneID: "p", cwd: "/work/heeler", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
        let layout = AgentRowLayout(rows: [[.init(.host), .init(.status), .init(.directory)]])
        #expect(AgentRowRenderer.render(layout: layout, agent: unknown).map { $0.map(\.text).joined() }
                == ["Studio Mac · /work/heeler"])
        #expect(AgentStatus.unknown.displayTitle == nil)
        #expect(AgentStatus(rawValue: "paused").displayTitle == "Paused")
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
