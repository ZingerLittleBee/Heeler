import Testing

@testable import Heeler

@Suite("Agent row layout resolver")
struct AgentRowLayoutResolverTests {
    @Test func initializationImportsTwoPluginRowsAndDefaultsThirdToDirectory() {
        let first: AgentRow = [.init(.workspace, bold: true), .init(.custom("branch"))]
        let second: AgentRow = [.init(.terminalTitle, dim: true)]
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(
            rows: [[.init(.stateIcon)] + first, second, [.init(.tab)]], rowGap: 2))
        let initial = AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: plugin)
        #expect(initial.rows == [first, second, [.init(.directory)]])
        #expect(initial.rowGap == 2)

        // An explicitly emptied third row stays empty after initialization.
        let saved = AgentRowLayout(rows: [first, second, []])
        #expect(AgentRowLayoutResolver.resolve(hostLayout: saved, pluginSnapshot: plugin) == saved)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: nil).rows
            == [[.init(.workspace), .init(.tab)], [.init(.pane), .init(.agent)],
                [.init(.directory)]])
    }

    @Test func savedLayoutsTakePrecedenceOverInitializedPluginRows() {
        let host = AgentRowLayout(rows: [[.init(.pane)]], rowGap: 3)
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(
            rows: [[.init(.workspace)]], rowGap: 1,
            rowsByAgent: ["claude": [[.init(.custom("pin_icon"))]]]), agentPanelSort: .priority)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: host, pluginSnapshot: plugin) == host)
        let resolvedPlugin = AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: plugin)
        #expect(resolvedPlugin == plugin.layout.withHeelerRow())
        #expect(resolvedPlugin.rows == [[.init(.workspace)], [], [.init(.directory)]] && resolvedPlugin.rowGap == 1)
        #expect(resolvedPlugin.rowsByAgent.isEmpty)
        #expect(AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: nil) == .consoleDefault)
        // An empty override is still a whole-layout choice, not inheritance.
        #expect(AgentRowLayoutResolver.resolve(hostLayout: AgentRowLayout(rows: []), pluginSnapshot: plugin).rows.isEmpty)
    }
}
